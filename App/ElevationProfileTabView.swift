import SwiftUI
import Charts
import CoreLocation
import GPXCore

extension SlopeCategory {
    var color: Color {
        switch self {
        case .gentle:   return .green
        case .moderate: return .yellow
        case .steep:    return .orange
        case .veryStep: return .red
        case .descent:  return .blue
        }
    }
}

enum ProfileMode: String, CaseIterable, Identifiable {
    case distance
    case time
    var id: String { rawValue }
    var label: String { self == .distance ? "Distance" : "Temps" }
}

enum ProfileMetric: String, CaseIterable, Identifiable {
    case altitude
    case speed
    var id: String { rawValue }
    var label: String { self == .altitude ? "Altitude" : "Vitesse" }
}

private enum MovementState {
    case moving
    case paused
    var label: String { self == .moving ? "En mouvement" : "Pause" }
    var color: Color { self == .moving ? .green : .gray }
}

/// Point d'une aire colorée. Les points consécutifs de même catégorie partagent un `runKey`, ce qui en
/// fait une série distincte dans Swift Charts → une aire locale au segment (pas reliée à tout le graphe).
private struct AreaPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let runKey: String
}

private struct ProfileLinePoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

/// Point de la courbe de fréquence cardiaque. `plotY` est la FC normalisée sur l'échelle d'altitude
/// (axe Y partagé) ; l'axe de droite ré-étiquette ces positions en bpm.
private struct HRPoint: Identifiable {
    let id: Int
    let x: Double
    let plotY: Double
}

/// Données complètes d'un point pour le cartouche affiché au survol.
private struct HoverSample {
    let x: Double
    let distanceKm: Double
    let altitude: Double
    let slope: Double
    let speed: Double      // vitesse en unité d'affichage (km/h ou nœuds)
    let plotY: Double      // valeur tracée sur l'axe Y (altitude ou vitesse)
    let hr: Double?
    let elapsed: TimeInterval?
    let clock: Date?
    let moving: Bool?
    let coordinate: CLLocationCoordinate2D?
}

struct ElevationProfileTabView: View {
    let activityId: UUID
    let activityType: ActivityType
    let repository: CoreDataActivityRepository
    @Binding var mode: ProfileMode
    @Binding var metric: ProfileMetric
    @Binding var highlightedCoordinate: CLLocationCoordinate2D?

    private var slopeScale: SlopeScale { activityType.slopeScale }
    private var speedScale: SpeedScale { activityType.speedScale }
    private var usesNM: Bool { activityType.usesNauticalUnits }
    private var speedUnitLabel: String { activityType.speedUnitLabel }
    private var distanceUnitLabel: String { usesNM ? "NM" : "km" }
    private func distanceDisplay(meters: Double) -> Double { meters / (usesNM ? 1852 : 1000) }
    private func speedDisplay(mps: Double) -> Double {
        let kmh = mps * 3.6
        return usesNM ? kmh / 1.852 : kmh
    }
    private func speedColor(_ c: SpeedCategory) -> Color {
        let v = c.rgb
        return Color(red: v.r, green: v.g, blue: v.b)
    }

    @State private var trimmedProfile: [ElevationProfilePoint] = []
    @State private var hasAltitude = false
    @State private var hasSpeed = false
    @State private var maxSpeedDisplay: Double = 0
    @State private var avgSpeedDisplay: Double = 0

    @State private var areaPoints: [AreaPoint] = []
    @State private var linePoints: [ProfileLinePoint] = []
    @State private var styleScale: [String: Color] = [:]
    @State private var xAxisLabel = "Distance (km)"

    @State private var slopeTimes: [SlopeCategory: TimeInterval] = [:]
    @State private var movingTime: TimeInterval = 0
    @State private var pausedTime: TimeInterval = 0
    // Plages temporelles de pause calculées sur le profil plein (mêmes que la légende) → coloriage cohérent du graphe décimé.
    @State private var pausedRanges: [ClosedRange<Date>] = []
    @AppStorage("pauseThresholdMinutes") private var pauseThresholdMinutes: Double = 5
    @AppStorage("pauseRadiusMeters") private var pauseRadiusMeters: Double = 40

    @State private var hrLine: [HRPoint] = []
    @State private var hrMin: Double = 0
    @State private var hrMax: Double = 0
    @State private var yDomainHi: Double = 0
    private var showHR: Bool { mode == .time && !hrLine.isEmpty && hrMax > hrMin }

    @State private var hoverSamples: [HoverSample] = []
    @State private var selectedIndex: Int?

    @State private var totalKm: Double = 0
    @State private var altMin: Double = 0
    @State private var altMax: Double = 0
    @State private var dPlus: Double = 0
    @State private var dMinus: Double = 0
    @State private var isLoading = true
    @State private var loadError: String?

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Chargement du profil…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Profil indisponible", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if metric == .altitude && !hasAltitude {
                ContentUnavailableView("Pas d'altitude", systemImage: "chart.xyaxis.line", description: Text("La trace ne contient pas de données d'altitude."))
            } else if metric == .speed && !hasSpeed {
                ContentUnavailableView("Pas de vitesse", systemImage: "speedometer", description: Text("La trace n'a pas d'horodatage exploitable pour calculer la vitesse."))
            } else {
                profileContent
            }
        }
        .task(id: "\(activityId)-\(pauseThresholdMinutes)-\(pauseRadiusMeters)") { await load() }
        .onChange(of: mode) { _, _ in
            buildChartData(from: trimmedProfile, mode: mode)
        }
        .onChange(of: metric) { _, _ in
            buildChartData(from: trimmedProfile, mode: mode)
        }
    }

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            statsBar
                .padding(.horizontal)

            if areaPoints.isEmpty {
                ContentUnavailableView("Temps indisponible", systemImage: "clock.badge.questionmark",
                                       description: Text("La trace n'a pas d'horodatage exploitable pour ce mode."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal)
                if metric == .altitude {
                    legend
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                } else {
                    speedLegend
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private var speedLegend: some View {
        HStack(spacing: 14) {
            ForEach(speedScale.categories, id: \.rawValue) { c in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(speedColor(c).opacity(0.8)).frame(width: 11, height: 11)
                    Text(speedScale.label(for: c)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var legendItems: [(label: String, color: Color, time: TimeInterval)] {
        switch mode {
        case .distance:
            return slopeScale.categories.map { (slopeScale.label(for: $0), $0.color, slopeTimes[$0] ?? 0) }
        case .time:
            return [
                (MovementState.moving.label, MovementState.moving.color, movingTime),
                (MovementState.paused.label, MovementState.paused.color, pausedTime)
            ]
        }
    }

    private var legend: some View {
        let items = legendItems
        let total = items.reduce(0) { $0 + $1.time }
        return HStack(alignment: .top, spacing: 18) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.color.opacity(0.65))
                            .frame(width: 11, height: 11)
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.formatDuration(item.time))
                        .font(.caption.monospacedDigit().bold())
                    if total > 0 {
                        Text("\(Int((item.time / total * 100).rounded())) %")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if showHR {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Rectangle().fill(.red).frame(width: 12, height: 2)
                        Text("Fréq. cardiaque")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(Int(hrMin))–\(Int(hrMax)) bpm")
                        .font(.caption.monospacedDigit().bold())
                }
            }
            Spacer()
        }
    }

    private static func formatDuration(_ s: TimeInterval) -> String {
        guard s >= 1 else { return "—" }
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        let sec = Int(s) % 60
        return m > 0 ? String(format: "%dm %02ds", m, sec) : String(format: "%ds", sec)
    }

    private var statsBar: some View {
        HStack(spacing: 24) {
            statBlock("Distance", String(format: "%.2f %@", totalKm, distanceUnitLabel))
            if metric == .speed {
                statBlock("Vitesse moy", String(format: "%.1f %@", avgSpeedDisplay, speedUnitLabel))
                statBlock("Vitesse max", String(format: "%.1f %@", maxSpeedDisplay, speedUnitLabel))
            } else {
                statBlock("Alt min", "\(Int(altMin.rounded())) m")
                statBlock("Alt max", "\(Int(altMax.rounded())) m")
                statBlock("D+", "\(Int(dPlus.rounded())) m")
                statBlock("D−", "\(Int(dMinus.rounded())) m")
            }
            Spacer()
        }
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().bold())
        }
    }

    private var chart: some View {
        Chart {
            ForEach(areaPoints) { p in
                AreaMark(
                    x: .value("x", p.x),
                    y: .value("y", p.y),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value("Segment", p.runKey))
                .opacity(0.65)
            }
            ForEach(linePoints) { p in
                LineMark(
                    x: .value("x", p.x),
                    y: .value("y", p.y)
                )
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            if showHR {
                ForEach(hrLine) { p in
                    LineMark(
                        x: .value("x", p.x),
                        y: .value("FC", p.plotY),
                        series: .value("série", "fc")
                    )
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.linear)
                }
            }
            if let i = selectedIndex, hoverSamples.indices.contains(i) {
                let s = hoverSamples[i]
                RuleMark(x: .value("x", s.x))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        hoverTooltip(s)
                    }
                RuleMark(y: .value("y", s.plotY))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("x", s.x), y: .value("y", s.plotY))
                    .foregroundStyle(.primary)
                    .symbolSize(45)
                if showHR, let hr = s.hr, hr > 0 {
                    PointMark(x: .value("x", s.x), y: .value("FC", (hr - hrMin) / (hrMax - hrMin) * max(yDomainHi, 1)))
                        .foregroundStyle(.red)
                        .symbolSize(40)
                }
            }
        }
        .chartForegroundStyleScale(domain: scaleDomain, range: scaleRange)
        .chartLegend(.hidden)
        .chartXAxisLabel(xAxisLabel)
        .chartYAxisLabel(metric == .speed ? "Vitesse (\(speedUnitLabel))" : "Altitude (m)")
        .chartYScale(domain: 0...max(yDomainHi, 1))
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
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let rect = geo[plotFrame]
                            let xInPlot = location.x - rect.origin.x
                            guard xInPlot >= 0, xInPlot <= rect.width,
                                  let xValue: Double = proxy.value(atX: xInPlot) else { return }
                            let idx = nearestIndex(to: xValue)
                            selectedIndex = idx
                            highlightedCoordinate = idx.flatMap { hoverSamples[$0].coordinate }
                        case .ended:
                            selectedIndex = nil
                            highlightedCoordinate = nil
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func hoverTooltip(_ s: HoverSample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hoverHeader(s)).font(.caption2.bold())
            if metric == .speed {
                tooltipRow("Vitesse", String(format: "%.1f %@", s.speed, speedUnitLabel), .teal)
            } else {
                tooltipRow("Altitude", "\(Int(s.altitude.rounded())) m", .primary)
                if mode == .distance {
                    let cat = slopeScale.category(for: s.slope)
                    tooltipRow("Pente", String(format: "%+.0f %%", s.slope), cat.color)
                }
            }
            if mode == .time {
                if let clock = s.clock {
                    tooltipRow("Heure", Self.clockFormatter.string(from: clock), .secondary)
                }
                if let hr = s.hr, hr > 0 {
                    tooltipRow("FC", "\(Int(hr.rounded())) bpm", .red)
                }
                if let moving = s.moving {
                    tooltipRow("État", moving ? "En mouvement" : "Pause", moving ? .green : .gray)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .fixedSize()
    }

    private func tooltipRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption2.monospacedDigit().bold()).foregroundStyle(color)
        }
    }

    private func hoverHeader(_ s: HoverSample) -> String {
        if mode == .distance {
            return String(format: "%.2f %@", s.distanceKm, distanceUnitLabel)
        }
        guard let e = s.elapsed else { return "" }
        let h = Int(e) / 3600, m = (Int(e) % 3600) / 60, sec = Int(e) % 60
        return h > 0 ? String(format: "%dh %02dm %02ds", h, m, sec) : String(format: "%dm %02ds", m, sec)
    }

    private func nearestIndex(to xValue: Double) -> Int? {
        guard !hoverSamples.isEmpty else { return nil }
        var lo = 0, hi = hoverSamples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if hoverSamples[mid].x < xValue { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 {
            let prev = hoverSamples[lo - 1]
            return abs(prev.x - xValue) <= abs(hoverSamples[lo].x - xValue) ? lo - 1 : lo
        }
        return lo
    }

    /// Graduations de l'axe FC (bpm ronds), positionnées sur l'échelle d'altitude.
    private var hrTicks: [(y: Double, bpm: Int)] {
        guard showHR else { return [] }
        let span = hrMax - hrMin
        let step: Double = span > 80 ? 40 : (span > 40 ? 20 : 10)
        let first = (hrMin / step).rounded(.up) * step
        var ticks: [(Double, Int)] = []
        var bpm = first
        while bpm <= hrMax {
            let y = (bpm - hrMin) / span * max(yDomainHi, 1)
            ticks.append((y, Int(bpm)))
            bpm += step
        }
        return ticks
    }

    /// Domaine et plage alignés (mêmes indices) pour la table de couleurs des séries.
    private var scaleDomain: [String] { Array(styleScale.keys) }
    private var scaleRange: [Color] {
        Array(styleScale.keys).map { styleScale[$0] ?? .clear }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            guard let data = try await repository.fetchTrackData(id: activityId), !data.isEmpty else {
                resetData()
                isLoading = false
                return
            }
            let trackPoints = try TrackPointCodec.decode(data)
            let raw = ElevationProfileBuilder.build(points: trackPoints)
            hasAltitude = !raw.isEmpty
            // Sans altitude (ex. voile), on retombe sur un profil « mouvement » pour la vitesse.
            let working = raw.isEmpty ? ElevationProfileBuilder.buildMotion(points: trackPoints) : raw
            let trimmed = hasAltitude
                ? ElevationProfileBuilder.decimate(working, tolerance: 1.0, maxPoints: 5_000)
                : Self.capped(working, maxN: 5_000)
            let summary = computeAltStats(profile: raw)

            trimmedProfile = trimmed
            hasSpeed = trimmed.compactMap(\.timestamp).count >= 2
            // Mêmes pauses que les cartes du détail (rayon + durée paramétrables) → temps cohérents.
            let minSec = pauseThresholdMinutes * 60
            slopeTimes = ElevationProfileBuilder.slopeTimesAndPause(raw, scale: slopeScale, pauseMinSeconds: minSec, pauseRadiusMeters: pauseRadiusMeters).byCategory
            let bd = ElevationProfileBuilder.timeBreakdown(working, pauseMinSeconds: minSec, pauseRadiusMeters: pauseRadiusMeters)
            movingTime = bd.ascending + bd.descending + bd.flat
            pausedTime = bd.paused
            pausedRanges = ElevationProfileBuilder.pausedTimeRanges(working, pauseMinSeconds: minSec, pauseRadiusMeters: pauseRadiusMeters)

            let speeds = speedSeries(trimmed)
            // Vitesse max hors pauses (le jitter GPS gonfle la vitesse à l'arrêt).
            maxSpeedDisplay = zip(trimmed, speeds).filter { p, _ in
                guard let t = p.timestamp, !pausedRanges.isEmpty else { return true }
                return !pausedRanges.contains { $0.contains(t) }
            }.map(\.1).max() ?? 0
            let totalMeters = trimmed.last?.distanceFromStart ?? 0
            avgSpeedDisplay = movingTime > 0 ? speedDisplay(mps: totalMeters / movingTime) : 0

            buildChartData(from: trimmed, mode: mode)

            altMin = summary.altMin
            altMax = summary.altMax
            dPlus = summary.dPlus
            dMinus = summary.dMinus
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func resetData() {
        areaPoints = []; linePoints = []; styleScale = [:]
        totalKm = 0; slopeTimes = [:]; movingTime = 0; pausedTime = 0; pausedRanges = []
        hasAltitude = false; hasSpeed = false; maxSpeedDisplay = 0; avgSpeedDisplay = 0
        trimmedProfile = []; hrLine = []; hoverSamples = []; selectedIndex = nil
        highlightedCoordinate = nil
    }

    /// Sous-échantillonnage uniforme (pour les profils sans altitude, où Douglas-Peucker ne convient pas).
    private static func capped(_ a: [ElevationProfilePoint], maxN: Int) -> [ElevationProfilePoint] {
        guard a.count > maxN else { return a }
        let step = Int((Double(a.count) / Double(maxN)).rounded(.up))
        var r = stride(from: 0, to: a.count, by: step).map { a[$0] }
        if let last = a.last, r.last?.distanceFromStart != last.distanceFromStart { r.append(last) }
        return r
    }

    /// Vitesse (unité d'affichage) lissée par point, dérivée de distance/temps. 0 si pas d'horodatage exploitable.
    private func speedSeries(_ profile: [ElevationProfilePoint]) -> [Double] {
        let n = profile.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var raw = [Double](repeating: 0, count: n)
        for i in 1..<n {
            guard let t0 = profile[i - 1].timestamp, let t1 = profile[i].timestamp else { raw[i] = raw[i - 1]; continue }
            let dt = t1.timeIntervalSince(t0)
            let dd = profile[i].distanceFromStart - profile[i - 1].distanceFromStart
            raw[i] = (dt > 0 && dt <= 600) ? dd / dt : raw[i - 1] // ignore les gros trous (>10 min)
        }
        raw[0] = n > 1 ? raw[1] : 0
        let w = 5
        var smoothed = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - w / 2), hi = min(n - 1, i + w / 2)
            var sum = 0.0
            for k in lo...hi { sum += raw[k] }
            smoothed[i] = sum / Double(hi - lo + 1)
        }
        return smoothed.map { speedDisplay(mps: $0) }
    }

    /// Construit les données du graphique selon le mode : axe distance + couleur de pente, ou axe temps
    /// + couleur mouvement/pause. Regroupe les segments contigus de même catégorie en aires distinctes.
    private func buildChartData(from profile: [ElevationProfilePoint], mode: ProfileMode) {
        guard profile.count >= 2 else {
            areaPoints = []; linePoints = []; styleScale = [:]; totalKm = 0; hrLine = []; hoverSamples = []; selectedIndex = nil
            return
        }
        totalKm = distanceDisplay(meters: profile.last?.distanceFromStart ?? 0)

        // Un segment [i,i+1] du profil affiché (décimé) est « en pause » s'il chevauche une plage de pause
        // calculée sur le profil plein. Robuste à la décimation, qui peut supprimer le point de début de pause.
        func isPaused(_ i: Int) -> Bool {
            guard mode == .time, !pausedRanges.isEmpty, i + 1 < profile.count,
                  let ta = profile[i].timestamp, let tb = profile[i + 1].timestamp else { return false }
            return pausedRanges.contains { ta < $0.upperBound && $0.lowerBound < tb }
        }
        // En pause, la vitesse réelle est nulle (jitter GPS = vitesse fantôme) → 0 aux deux extrémités des segments en pause
        // (la courbe forme une bande plate à zéro, pas une rampe inclinée vers le point de fin de pause).
        var speeds: [Double] = metric == .speed ? speedSeries(profile) : []
        if metric == .speed {
            for k in speeds.indices where isPaused(k) || (k > 0 && isPaused(k - 1)) { speeds[k] = 0 }
        }
        func yValue(_ i: Int) -> Double {
            metric == .speed ? (speeds.indices.contains(i) ? speeds[i] : 0) : profile[i].altitude
        }
        yDomainHi = metric == .speed
            ? (speeds.max() ?? 1) * 1.1
            : (profile.map(\.altitude).max() ?? 1) * 1.05

        let xs: [Double]
        switch mode {
        case .distance:
            xAxisLabel = "Distance (\(distanceUnitLabel))"
            xs = profile.map { distanceDisplay(meters: $0.distanceFromStart) }
            hrLine = []
        case .time:
            let stamps = profile.compactMap { $0.timestamp }
            guard let t0 = stamps.first, let tLast = stamps.last, tLast > t0 else {
                areaPoints = []; linePoints = []; styleScale = [:]; hrLine = []; hoverSamples = []; selectedIndex = nil
                return
            }
            let useMinutes = tLast.timeIntervalSince(t0) < 5400
            xAxisLabel = useMinutes ? "Temps (min)" : "Temps (h)"
            let div = useMinutes ? 60.0 : 3600.0
            var lastX = 0.0
            xs = profile.map { p in
                if let t = p.timestamp { lastX = t.timeIntervalSince(t0) / div }
                return lastX
            }
            buildHeartRate(from: profile, xs: xs)
        }

        func segmentStyle(_ i: Int) -> (key: String, color: Color) {
            if isPaused(i) { return (MovementState.paused.label, MovementState.paused.color) }
            if metric == .speed {
                let c = speedScale.category(for: speeds.indices.contains(i) ? speeds[i] : 0)
                return (speedScale.label(for: c), speedColor(c))
            }
            switch mode {
            case .distance:
                let c = slopeScale.category(for: profile[i].slope)
                return (slopeScale.label(for: c), c.color)
            case .time:
                return (MovementState.moving.label, MovementState.moving.color)
            }
        }

        linePoints = profile.enumerated().map { idx, p in
            ProfileLinePoint(id: idx, x: xs[idx], y: yValue(idx))
        }

        var points: [AreaPoint] = []
        var scale: [String: Color] = [:]
        var rowId = 0
        var runIndex = 0
        var s = 0
        let segmentCount = profile.count - 1
        while s < segmentCount {
            let style = segmentStyle(s)
            var e = s
            while e + 1 < segmentCount, segmentStyle(e + 1).key == style.key { e += 1 }
            // Le run couvre les points [s ... e+1] ; le point e+1 est partagé avec le run suivant (continuité).
            let key = String(format: "%05d", runIndex)
            scale[key] = style.color
            for k in s...(e + 1) {
                points.append(AreaPoint(id: rowId, x: xs[k], y: yValue(k), runKey: key))
                rowId += 1
            }
            runIndex += 1
            s = e + 1
        }
        areaPoints = points
        styleScale = scale

        let t0 = (mode == .time) ? profile.compactMap(\.timestamp).first : nil
        hoverSamples = profile.enumerated().map { i, p in
            let elapsed: TimeInterval? = (mode == .time) ? (p.timestamp.flatMap { ts in t0.map { ts.timeIntervalSince($0) } }) : nil
            let moving: Bool? = (mode == .time) ? !isPaused(i) : nil
            let coordinate: CLLocationCoordinate2D? = (p.latitude != nil && p.longitude != nil)
                ? CLLocationCoordinate2D(latitude: p.latitude!, longitude: p.longitude!) : nil
            let spd = speeds.indices.contains(i) ? speeds[i] : 0
            return HoverSample(x: xs[i], distanceKm: distanceDisplay(meters: p.distanceFromStart), altitude: p.altitude, slope: p.slope, speed: spd, plotY: yValue(i), hr: p.heartRate, elapsed: elapsed, clock: p.timestamp, moving: moving, coordinate: coordinate)
        }
        selectedIndex = nil
        highlightedCoordinate = nil
    }

    /// Construit la courbe FC normalisée sur l'échelle d'altitude (axe Y partagé), si des données existent.
    private func buildHeartRate(from profile: [ElevationProfilePoint], xs: [Double]) {
        let hrs = profile.compactMap(\.heartRate).filter { $0 > 0 }
        guard hrs.count >= 2, let lo = hrs.min(), let hi = hrs.max(), hi > lo else {
            hrLine = []; hrMin = 0; hrMax = 0
            return
        }
        hrMin = lo
        hrMax = hi
        let span = hi - lo
        var line: [HRPoint] = []
        var rowId = 0
        for (idx, p) in profile.enumerated() {
            guard let hr = p.heartRate, hr > 0 else { continue }
            let plotY = (hr - lo) / span * max(yDomainHi, 1)
            line.append(HRPoint(id: rowId, x: xs[idx], plotY: plotY))
            rowId += 1
        }
        hrLine = line
    }


    private func computeAltStats(profile: [ElevationProfilePoint]) -> (altMin: Double, altMax: Double, dPlus: Double, dMinus: Double) {
        guard !profile.isEmpty else { return (0, 0, 0, 0) }
        var minAlt = profile[0].altitude
        var maxAlt = profile[0].altitude
        var dPlus: Double = 0
        var dMinus: Double = 0
        var anchor = profile[0].altitude
        let threshold = 3.0
        for p in profile.dropFirst() {
            minAlt = min(minAlt, p.altitude)
            maxAlt = max(maxAlt, p.altitude)
            let delta = p.altitude - anchor
            if delta >= threshold {
                dPlus += delta
                anchor = p.altitude
            } else if delta <= -threshold {
                dMinus += -delta
                anchor = p.altitude
            }
        }
        return (minAlt, maxAlt, dPlus, dMinus)
    }
}
