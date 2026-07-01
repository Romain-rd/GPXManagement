import SwiftUI
import Charts
import CoreLocation
import GPXCore
import GPXRender

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

// Types du graphe (SlopeAreaPoint / SlopeLinePoint / SlopeHRPoint / SlopeHoverSample) et rendu interactif
// (crosshair, survol↔carte, sélection de plage) : partagés avec l'éditeur de parcours → voir SlopeProfileChart.

struct ElevationProfileTabView: View {
    let activityId: UUID
    let activityType: ActivityType
    let repository: CoreDataActivityRepository
    /// D+/D− stockés (stats officielles) — affichés tels quels pour coller exactement à la liste.
    var storedGain: Double = 0
    var storedLoss: Double = 0
    @Binding var mode: ProfileMode
    @Binding var metric: ProfileMetric
    @Binding var highlightedCoordinate: CLLocationCoordinate2D?
    /// Plage surlignée en mètres depuis le départ (segment survolé dans le tableau).
    var highlightedDistanceRange: ClosedRange<Double>? = nil
    /// Création de segment : appelé en fin de glissement avec les distances (m) de début et fin.
    var onSelectRange: ((Double, Double) -> Void)? = nil

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

    @State private var areaPoints: [SlopeAreaPoint] = []
    @State private var linePoints: [SlopeLinePoint] = []
    @State private var styleScale: [String: Color] = [:]
    @State private var xAxisLabel = "Distance (km)"

    @State private var slopeTimes: [SlopeCategory: TimeInterval] = [:]
    @State private var movingTime: TimeInterval = 0
    @State private var pausedTime: TimeInterval = 0
    // Plages temporelles de pause calculées sur le profil plein (mêmes que la légende) → coloriage cohérent du graphe décimé.
    @State private var pausedRanges: [ClosedRange<Date>] = []
    @AppStorage("pauseThresholdMinutes") private var pauseThresholdMinutes: Double = 5
    @AppStorage("pauseRadiusMeters") private var pauseRadiusMeters: Double = 40
    /// Axe vertical adapté au dénivelé (départ ≠ 0), comme la lib JS du web ; sinon depuis 0. Partagé avec le parcours.
    @AppStorage("profileFitElevation") private var fitElevation = true

    @State private var hrLine: [SlopeHRPoint] = []
    @State private var hrMin: Double = 0
    @State private var hrMax: Double = 0
    @State private var yDomainHi: Double = 0
    private var showHR: Bool { mode == .time && !hrLine.isEmpty && hrMax > hrMin }

    @State private var hoverSamples: [SlopeHoverSample] = []

    @State private var totalKm: Double = 0
    @State private var xDomainHi: Double = 0
    @State private var altMin: Double = 0
    @State private var altMax: Double = 0
    @State private var dPlus: Double = 0
    @State private var dMinus: Double = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isGeneratingElevation = false
    @State private var elevationMessage: String?

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
                ContentUnavailableView {
                    Label("Pas d'altitude", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(elevationMessage ?? "La trace ne contient pas de données d'altitude.")
                } actions: {
                    Button {
                        Task { await generateElevation() }
                    } label: {
                        if isGeneratingElevation {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Calcul de l'altitude…")
                            }
                        } else {
                            Label("Générer le profil altimétrique", systemImage: "mountain.2")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGeneratingElevation)
                }
            } else if metric == .speed && !hasSpeed {
                ContentUnavailableView("Pas de vitesse", systemImage: "speedometer", description: Text("La trace n'a pas d'horodatage exploitable pour calculer la vitesse."))
            } else {
                profileContent
            }
        }
        .task(id: "\(activityId)-\(pauseThresholdMinutes)-\(pauseRadiusMeters)-\(AppServices.shared.libraryRevision)") { await load() }
        .onChange(of: mode) { _, _ in
            buildChartData(from: trimmedProfile, mode: mode)
        }
        .onChange(of: metric) { _, _ in
            buildChartData(from: trimmedProfile, mode: mode)
        }
    }

    private func generateElevation() async {
        isGeneratingElevation = true
        elevationMessage = nil
        defer { isGeneratingElevation = false }
        switch await AppServices.shared.generateElevationProfile(id: activityId) {
        case .enriched:
            await load()
        case .noCoverage:
            elevationMessage = "Aucune altitude trouvée pour cette trace (hors couverture des données disponibles)."
        case .failed(let m):
            elevationMessage = "Échec : \(m)"
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
            if metric == .altitude && mode == .distance {
                Button { fitElevation.toggle() } label: {
                    Image(systemName: fitElevation ? "arrow.up.and.down.square.fill" : "arrow.up.and.down.square")
                }
                .buttonStyle(.borderless)
                .help(fitElevation ? "Axe vertical adapté au dénivelé (départ ≠ 0) — cliquer pour partir de 0"
                                   : "Axe vertical depuis 0 — cliquer pour l'adapter au dénivelé")
            }
        }
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().bold())
        }
    }

    /// Domaine vertical : adapté au dénivelé (comme le web) en mode altitude/distance si l'option est active, sinon 0.
    private var yBounds: (lo: Double, hi: Double) {
        if metric == .altitude, mode == .distance, fitElevation {
            let pad = max((altMax - altMin) * 0.08, 10)
            return (altMin - pad, altMax + pad)
        }
        return (0, max(yDomainHi, 1))
    }
    /// Segment survolé dans le tableau (mètres) converti en unités X du graphe, pour la bande surlignée.
    private var highlightXRange: ClosedRange<Double>? {
        guard let range = highlightedDistanceRange, hoverSamples.count == trimmedProfile.count, !hoverSamples.isEmpty else { return nil }
        let lo = nearestProfileIndex(toMeters: range.lowerBound)
        let hi = nearestProfileIndex(toMeters: range.upperBound)
        guard hi > lo else { return nil }
        return hoverSamples[lo].x...hoverSamples[hi].x
    }

    private var chart: some View {
        SlopeProfileChart(
            area: areaPoints, line: linePoints, styleScale: styleScale, hover: hoverSamples,
            hrLine: showHR ? hrLine : [], hrTicks: showHR ? hrTicks : [],
            xDomainHi: xDomainHi, yDomainLo: yBounds.lo, yDomainHi: yBounds.hi,
            xAxisLabel: xAxisLabel, yAxisLabel: metric == .speed ? "Vitesse (\(speedUnitLabel))" : "Altitude (m)",
            highlightedCoordinate: $highlightedCoordinate,
            highlightRange: highlightXRange,
            onSelectRange: onSelectRange,
            tooltip: { s in hoverTooltip(s) }
        )
    }

    private func nearestProfileIndex(toMeters meters: Double) -> Int {
        var lo = 0, hi = trimmedProfile.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if trimmedProfile[mid].distanceFromStart < meters { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    @ViewBuilder
    private func hoverTooltip(_ s: SlopeHoverSample) -> some View {
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

    private func hoverHeader(_ s: SlopeHoverSample) -> String {
        if mode == .distance {
            return String(format: "%.2f %@", s.distanceKm, distanceUnitLabel)
        }
        guard let e = s.elapsed else { return "" }
        let h = Int(e) / 3600, m = (Int(e) % 3600) / 60, sec = Int(e) % 60
        return h > 0 ? String(format: "%dh %02dm %02ds", h, m, sec) : String(format: "%dm %02ds", m, sec)
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
            // Seuil élevé : une sortie ordinaire (jusqu'à ~20 000 points) est affichée intégralement. La décimation
            // Douglas-Peucker écrase les montées régulières (profil quasi rectiligne) → réservée aux traces énormes.
            let trimmed = hasAltitude
                ? ElevationProfileBuilder.decimate(working, tolerance: 0.5, maxPoints: 20_000)
                : Self.capped(working, maxN: 20_000)
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
            // D+/D− : valeurs stockées (identiques à la liste) ; repli sur le calcul local si non fournies.
            dPlus = storedGain > 0 ? storedGain : summary.dPlus
            dMinus = storedLoss > 0 ? storedLoss : summary.dMinus
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func resetData() {
        areaPoints = []; linePoints = []; styleScale = [:]
        totalKm = 0; xDomainHi = 0; slopeTimes = [:]; movingTime = 0; pausedTime = 0; pausedRanges = []
        hasAltitude = false; hasSpeed = false; maxSpeedDisplay = 0; avgSpeedDisplay = 0
        trimmedProfile = []; hrLine = []; hoverSamples = []
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
            areaPoints = []; linePoints = []; styleScale = [:]; totalKm = 0; hrLine = []; hoverSamples = []
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
                areaPoints = []; linePoints = []; styleScale = [:]; hrLine = []; hoverSamples = []
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
        // Domaine X explicite = dernière valeur, sinon Swift Charts arrondit vers le haut et la courbe n'atteint pas le bord droit.
        xDomainHi = xs.last ?? 0

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
            SlopeLinePoint(id: idx, x: xs[idx], y: yValue(idx))
        }

        var points: [SlopeAreaPoint] = []
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
                points.append(SlopeAreaPoint(id: rowId, x: xs[k], y: yValue(k), runKey: key))
                rowId += 1
            }
            runIndex += 1
            s = e + 1
        }
        areaPoints = points
        styleScale = scale

        let t0 = (mode == .time) ? profile.compactMap(\.timestamp).first : nil
        let hrSpan = hrMax - hrMin
        hoverSamples = profile.enumerated().map { i, p in
            let elapsed: TimeInterval? = (mode == .time) ? (p.timestamp.flatMap { ts in t0.map { ts.timeIntervalSince($0) } }) : nil
            let moving: Bool? = (mode == .time) ? !isPaused(i) : nil
            let coordinate: CLLocationCoordinate2D? = (p.latitude != nil && p.longitude != nil)
                ? CLLocationCoordinate2D(latitude: p.latitude!, longitude: p.longitude!) : nil
            let spd = speeds.indices.contains(i) ? speeds[i] : 0
            let hrPlotY: Double? = (mode == .time && hrSpan > 0) ? p.heartRate.flatMap { $0 > 0 ? ($0 - hrMin) / hrSpan * max(yDomainHi, 1) : nil } : nil
            return SlopeHoverSample(x: xs[i], distanceKm: distanceDisplay(meters: p.distanceFromStart), altitude: p.altitude, slope: p.slope, plotY: yValue(i), coordinate: coordinate, speed: spd, hr: p.heartRate, hrPlotY: hrPlotY, elapsed: elapsed, clock: p.timestamp, moving: moving)
        }
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
        var line: [SlopeHRPoint] = []
        var rowId = 0
        for (idx, p) in profile.enumerated() {
            guard let hr = p.heartRate, hr > 0 else { continue }
            let plotY = (hr - lo) / span * max(yDomainHi, 1)
            line.append(SlopeHRPoint(id: rowId, x: xs[idx], plotY: plotY))
            rowId += 1
        }
        hrLine = line
    }


    private func computeAltStats(profile: [ElevationProfilePoint]) -> (altMin: Double, altMax: Double, dPlus: Double, dMinus: Double) {
        guard !profile.isEmpty else { return (0, 0, 0, 0) }
        let alts = profile.map(\.altitude)
        // Même calcul de D+/D− que les stats stockées (ActivityStatsCalculator) : lissage EMA α=0,2 + hystérésis 3 m.
        var smoothed = alts
        let alpha = 0.2
        for i in 1..<smoothed.count { smoothed[i] = alpha * alts[i] + (1 - alpha) * smoothed[i - 1] }
        var dPlus: Double = 0
        var dMinus: Double = 0
        var anchor = smoothed[0]
        let threshold = 3.0
        for value in smoothed.dropFirst() {
            let delta = value - anchor
            if delta >= threshold { dPlus += delta; anchor = value }
            else if delta <= -threshold { dMinus += -delta; anchor = value }
        }
        return (alts.min() ?? 0, alts.max() ?? 0, dPlus, dMinus)
    }
}

// MARK: - Courbe FC pour les séances sans GPS

