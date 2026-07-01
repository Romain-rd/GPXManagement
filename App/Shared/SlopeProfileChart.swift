import SwiftUI
import Charts
import CoreLocation
import GPXCore
import GPXRender

/// Point d'une aire colorée : les points consécutifs de même catégorie partagent un `runKey` → série distincte
/// dans Swift Charts, donc une aire locale au segment (pente) plutôt qu'une seule aire reliée à tout le graphe.
struct SlopeAreaPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let runKey: String
}

struct SlopeLinePoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

struct SlopeHRPoint: Identifiable {
    let id: Int
    let x: Double
    let plotY: Double
}

/// Données d'un point pour le cartouche de survol + la synchro carte (coordonnée).
struct SlopeHoverSample {
    let x: Double
    let distanceKm: Double
    let altitude: Double
    let slope: Double
    let plotY: Double
    let coordinate: CLLocationCoordinate2D?
    var speed: Double = 0
    var hr: Double? = nil
    /// Position Y (échelle d'altitude partagée) du point FC au survol ; nil si pas de FC.
    var hrPlotY: Double? = nil
    var elapsed: TimeInterval? = nil
    var clock: Date? = nil
    var moving: Bool? = nil
}

/// Données prêtes à tracer pour un profil altitude/distance coloré par pente.
struct SlopeProfileData {
    var area: [SlopeAreaPoint] = []
    var line: [SlopeLinePoint] = []
    var styleScale: [String: Color] = [:]
    var hover: [SlopeHoverSample] = []
    var xDomainHi: Double = 0
    var altMin: Double = 0
    var altMax: Double = 0
    var isEmpty: Bool { line.count < 2 }

    /// Domaine vertical. `fit` (comme la lib JS du web) : [altMin − marge, altMax + marge], marge = 8 % du dénivelé
    /// (min 10 m) → l'axe ne part pas de 0 et l'échelle colle au dénivelé réel. Sinon échelle classique depuis 0.
    func yDomain(fit: Bool) -> (lo: Double, hi: Double) {
        if fit {
            let pad = Swift.max((altMax - altMin) * 0.08, 10)
            return (altMin - pad, altMax + pad)
        }
        return (0, altMax * 1.05)
    }

    /// Construit les données (axe distance en km, Y = altitude, couleur par catégorie de pente) depuis un profil.
    static func build(profile: [ElevationProfilePoint], slopeScale: SlopeScale) -> SlopeProfileData {
        guard profile.count >= 2 else { return SlopeProfileData() }
        let xs = profile.map { $0.distanceFromStart / 1000 }
        func yAt(_ i: Int) -> Double { profile[i].altitude }
        func style(_ i: Int) -> (key: String, color: Color) {
            let c = slopeScale.category(for: profile[i].slope)
            return (slopeScale.label(for: c), c.color)
        }
        var area: [SlopeAreaPoint] = []
        var scale: [String: Color] = [:]
        var rowId = 0, runIndex = 0, s = 0
        let segCount = profile.count - 1
        while s < segCount {
            let st = style(s)
            var e = s
            while e + 1 < segCount, style(e + 1).key == st.key { e += 1 }
            // Le run couvre [s ... e+1] ; le point e+1 est partagé avec le run suivant (continuité de l'aire).
            let key = String(format: "%05d", runIndex)
            scale[key] = st.color
            for k in s...(e + 1) { area.append(SlopeAreaPoint(id: rowId, x: xs[k], y: yAt(k), runKey: key)); rowId += 1 }
            runIndex += 1
            s = e + 1
        }
        let line = profile.indices.map { SlopeLinePoint(id: $0, x: xs[$0], y: yAt($0)) }
        let hover = profile.enumerated().map { i, p -> SlopeHoverSample in
            let coord = (p.latitude != nil && p.longitude != nil)
                ? CLLocationCoordinate2D(latitude: p.latitude!, longitude: p.longitude!) : nil
            return SlopeHoverSample(x: xs[i], distanceKm: p.distanceFromStart / 1000, altitude: p.altitude,
                                    slope: p.slope, plotY: yAt(i), coordinate: coord)
        }
        let alts = profile.map(\.altitude)
        return SlopeProfileData(area: area, line: line, styleScale: scale, hover: hover,
                                xDomainHi: xs.last ?? 0, altMin: alts.min() ?? 0, altMax: alts.max() ?? 0)
    }
}

/// Graphe de profil interactif partagé (activité + éditeur de parcours) : aire colorée par pente, crosshair au
/// survol, synchro `highlightedCoordinate` ↔ carte, zoom horizontal, jonctions d'étape déplaçables optionnelles.
struct SlopeProfileChart<Tooltip: View>: View {
    let area: [SlopeAreaPoint]
    let line: [SlopeLinePoint]
    let styleScale: [String: Color]
    let hover: [SlopeHoverSample]
    var hrLine: [SlopeHRPoint] = []
    var hrTicks: [(y: Double, bpm: Int)] = []
    let xDomainHi: Double
    var yDomainLo: Double = 0
    let yDomainHi: Double
    var xAxisLabel: String = "Distance (km)"
    var yAxisLabel: String = "Altitude (m)"
    @Binding var highlightedCoordinate: CLLocationCoordinate2D?
    /// Fenêtre X visible (zoom) ; nil = tout le graphe.
    var visibleDomain: ClosedRange<Double>? = nil
    /// Bande surlignée (segment) en unités X.
    var highlightRange: ClosedRange<Double>? = nil
    /// Jonctions d'étape (positions en unités X = km) → barres déplaçables.
    var junctions: [Double] = []
    var onSelectRange: ((Double, Double) -> Void)? = nil
    /// Déplacement d'une jonction : (index de la jonction, nouvelle position X en km). Si fourni, le glissement
    /// déplace la jonction la plus proche au lieu de sélectionner une plage.
    var onJunctionDrag: ((Int, Double) -> Void)? = nil
    var onJunctionDragEnded: (() -> Void)? = nil
    @ViewBuilder var tooltip: (SlopeHoverSample) -> Tooltip

    @State private var selectedIndex: Int?
    @State private var dragStart: Int?
    @State private var dragCurrent: Int?
    @State private var grabbedJunction: Int?

    private var scaleDomain: [String] { Array(styleScale.keys) }
    private var scaleRange: [Color] { Array(styleScale.keys).map { styleScale[$0] ?? .clear } }
    private var showHR: Bool { !hrLine.isEmpty }

    private var selectionBand: ClosedRange<Double>? {
        if let a = dragStart, let b = dragCurrent, a != b, hover.indices.contains(a), hover.indices.contains(b) {
            return Swift.min(hover[a].x, hover[b].x)...Swift.max(hover[a].x, hover[b].x)
        }
        return highlightRange
    }

    var body: some View {
        Chart {
            if let band = selectionBand {
                RectangleMark(xStart: .value("x", band.lowerBound), xEnd: .value("x", band.upperBound))
                    .foregroundStyle(Color.accentColor.opacity(0.16))
            }
            ForEach(area) { p in
                AreaMark(x: .value("x", p.x), y: .value("y", p.y), stacking: .unstacked)
                    .foregroundStyle(by: .value("Segment", p.runKey))
                    .opacity(0.65)
            }
            ForEach(line) { p in
                LineMark(x: .value("x", p.x), y: .value("y", p.y))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(showHR ? hrLine : []) { p in
                LineMark(x: .value("x", p.x), y: .value("FC", p.plotY), series: .value("série", "fc"))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.linear)
            }
            ForEach(Array(junctions.enumerated()), id: \.offset) { _, jx in
                RuleMark(x: .value("x", jx))
                    .foregroundStyle(.orange.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let i = selectedIndex, hover.indices.contains(i) {
                let s = hover[i]
                RuleMark(x: .value("x", s.x))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(s)
                    }
                RuleMark(y: .value("y", s.plotY))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("x", s.x), y: .value("y", s.plotY))
                    .foregroundStyle(.primary)
                    .symbolSize(45)
                if let hy = s.hrPlotY {
                    PointMark(x: .value("x", s.x), y: .value("FC", hy))
                        .foregroundStyle(.red)
                        .symbolSize(40)
                }
            }
        }
        .chartForegroundStyleScale(domain: scaleDomain, range: scaleRange)
        .chartLegend(.hidden)
        .chartXAxisLabel(xAxisLabel)
        .chartYAxisLabel(yAxisLabel)
        .chartXScale(domain: visibleDomain ?? 0...Swift.max(xDomainHi, 1))
        .chartYScale(domain: yDomainLo...Swift.max(yDomainHi, yDomainLo + 1))
        .chartYAxis {
            AxisMarks(position: .leading)
            if showHR {
                AxisMarks(position: .trailing, values: hrTicks.map(\.y)) { value in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisTick().foregroundStyle(.red)
                    if let y = value.as(Double.self), let tick = hrTicks.first(where: { abs($0.y - y) < 0.5 }) {
                        AxisValueLabel { Text("\(tick.bpm)").foregroundStyle(.red) }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard dragStart == nil, grabbedJunction == nil else { return }
                        switch phase {
                        case .active(let location):
                            guard let idx = sampleIndex(at: location, proxy: proxy, geo: geo) else { return }
                            selectedIndex = idx
                            highlightedCoordinate = hover[idx].coordinate
                        case .ended:
                            selectedIndex = nil
                            highlightedCoordinate = nil
                        }
                    }
                    .gesture(dragGesture(proxy: proxy, geo: geo),
                             including: (onJunctionDrag == nil && onSelectRange == nil) ? .none : .all)
            }
        }
    }

    private func dragGesture(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: onJunctionDrag != nil ? 0 : 6)
            .onChanged { value in
                guard let xVal = xValue(at: value.location, proxy: proxy, geo: geo) else { return }
                if onJunctionDrag != nil {
                    // Déplacement d'une jonction : on saisit la plus proche au démarrage, puis on la suit.
                    if grabbedJunction == nil {
                        guard let startX = xValue(at: value.startLocation, proxy: proxy, geo: geo) else { return }
                        grabbedJunction = nearestJunction(to: startX)
                    }
                    if let g = grabbedJunction {
                        onJunctionDrag?(g, xVal)
                        if let idx = nearestIndex(to: xVal) { highlightedCoordinate = hover[idx].coordinate }
                    }
                } else {
                    guard let start = sampleIndex(at: value.startLocation, proxy: proxy, geo: geo),
                          let current = sampleIndex(at: value.location, proxy: proxy, geo: geo) else { return }
                    dragStart = start; dragCurrent = current; selectedIndex = nil
                    if hover.indices.contains(current) { highlightedCoordinate = hover[current].coordinate }
                }
            }
            .onEnded { _ in
                if onJunctionDrag != nil {
                    grabbedJunction = nil
                    highlightedCoordinate = nil
                    onJunctionDragEnded?()
                } else {
                    defer { dragStart = nil; dragCurrent = nil; highlightedCoordinate = nil }
                    guard let a = dragStart, let b = dragCurrent, hover.indices.contains(a), hover.indices.contains(b) else { return }
                    let lo = Swift.min(a, b), hi = Swift.max(a, b)
                    guard hi > lo else { return }
                    onSelectRange?(hover[lo].distanceKm * 1000, hover[hi].distanceKm * 1000)
                }
            }
    }

    private func nearestJunction(to x: Double) -> Int? {
        guard !junctions.isEmpty else { return nil }
        var best = 0, bestD = Double.greatestFiniteMagnitude
        for (i, jx) in junctions.enumerated() { let d = abs(jx - x); if d < bestD { bestD = d; best = i } }
        return best
    }

    private func xValue(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Double? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let rect = geo[plotFrame]
        let xInPlot = Swift.min(Swift.max(location.x - rect.origin.x, 0), rect.width)
        return proxy.value(atX: xInPlot)
    }

    private func sampleIndex(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard let x = xValue(at: location, proxy: proxy, geo: geo) else { return nil }
        return nearestIndex(to: x)
    }

    private func nearestIndex(to xValue: Double) -> Int? {
        guard !hover.isEmpty else { return nil }
        var lo = 0, hi = hover.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if hover[mid].x < xValue { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 {
            let prev = hover[lo - 1]
            return abs(prev.x - xValue) <= abs(hover[lo].x - xValue) ? lo - 1 : lo
        }
        return lo
    }
}
