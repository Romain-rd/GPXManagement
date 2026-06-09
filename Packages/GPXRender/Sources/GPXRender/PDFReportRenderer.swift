import SwiftUI
import Charts
import AppKit
import MapKit
import GPXCore
import GPXMapKit

public enum PDFReportError: Error, LocalizedError {
    case noTrackData
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .noTrackData:  return "Cette activité ne contient pas de trace."
        case .renderFailed: return "Échec de la génération du PDF."
        }
    }
}

struct ProfileChartSample: Identifiable {
    let id: Int
    let x: Double
    let altitude: Double
    let runKey: String
}

struct PDFHRSample: Identifiable {
    let id: Int
    let x: Double
    let plotY: Double
}

struct PDFHRTick {
    let y: Double
    let bpm: Int
}

/// Données du profil en mode temps (aire mouvement/pause + fréquence cardiaque).
struct PDFTimeProfile {
    let samples: [ProfileChartSample]
    let scale: [String: Color]
    let axisLabel: String
    let hr: [PDFHRSample]
    let hrTicks: [PDFHRTick]
    let yDomainHi: Double
    let available: Bool

    static let empty = PDFTimeProfile(samples: [], scale: [:], axisLabel: "", hr: [], hrTicks: [], yDomainHi: 0, available: false)
}

@MainActor
public enum PDFReportRenderer {
    // A4 portrait en points (72 dpi).
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let trackColor = NSColor.systemRed

    public static func render(activity: ActivitySummary, repository: CoreDataActivityRepository, layer: MapLayer) async throws -> Data {
        guard let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty else {
            throw PDFReportError.noTrackData
        }
        let points = try TrackPointCodec.decode(data)

        // Carte de la trace (cadrée sur le parcours), tracé rouge avec liseré blanc pour la lisibilité.
        var mapImage: NSImage?
        if let mapRect = boundingMapRect(points) {
            let overlay = TrackOverlayInput(activityId: activity.id, activityType: activity.activityType, coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
            if let png = try? await MapImageExporter.renderPNG(layer: layer, mapRect: mapRect, tracks: [overlay], maxDimension: 2200, trackColor: trackColor) {
                mapImage = NSImage(data: png)
            }
        }

        let profile = ElevationProfileBuilder.build(points: points)
        let (distanceSamples, distanceScale) = slopeRuns(from: profile, scale: activity.activityType.slopeScale)
        let timeProfile = movementRuns(from: profile)
        let movement = Self.movementSplit(profile)

        let page1 = PDFReportPage(activity: activity, mapImage: mapImage, movingTime: profile.isEmpty ? nil : movement.moving)
        let page2 = PDFProfilesPage(
            activity: activity,
            distanceSamples: distanceSamples,
            distanceScale: distanceScale,
            time: timeProfile,
            movingTime: movement.moving,
            pausedTime: movement.paused
        )

        var pages: [AnyView] = [AnyView(page1)]
        if !distanceSamples.isEmpty || timeProfile.available {
            pages.append(AnyView(page2))
        }
        return try renderPages(pages)
    }

    private static func renderPages(_ pages: [AnyView]) throws -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFReportError.renderFailed
        }
        for page in pages {
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(pageSize)
            var emitted = false
            renderer.render { _, draw in
                guard !emitted else { return }
                emitted = true
                pdfContext.beginPDFPage(nil)
                draw(pdfContext)
                pdfContext.endPDFPage()
            }
        }
        pdfContext.closePDF()
        guard pdfData.length > 0 else { throw PDFReportError.renderFailed }
        return pdfData as Data
    }

    // MARK: - Données des profils

    /// Regroupe les points en segments contigus de même pente (chaque run = une aire colorée distincte).
    // Seuils de pause (paramétrés par l'utilisateur, partagés avec l'app/profil).
    static var pauseMinSeconds: Double { (UserDefaults.standard.object(forKey: "pauseThresholdMinutes") as? Double ?? 5) * 60 }
    static var pauseRadiusMeters: Double { UserDefaults.standard.object(forKey: "pauseRadiusMeters") as? Double ?? 40 }

    /// Temps mouvement/pause cohérent avec l'app : mouvement = montée+descente+plat, pause = arrêts ≥ seuil.
    static func movementSplit(_ profile: [ElevationProfilePoint]) -> (moving: TimeInterval, paused: TimeInterval) {
        let bd = ElevationProfileBuilder.timeBreakdown(profile, pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        return (bd.ascending + bd.descending + bd.flat, bd.paused)
    }

    static func slopeRuns(from profile: [ElevationProfilePoint], scale: SlopeScale = .percent) -> ([ProfileChartSample], [String: Color]) {
        guard profile.count >= 2 else { return ([], [:]) }
        // Profil en distance : uniquement les bandes de pente (la pause est temporelle, sans sens sur l'axe distance).
        let categories = (0..<(profile.count - 1)).map { scale.category(for: profile[$0].slope) }
        return runs(profile: profile, xs: profile.map { $0.distanceFromStart / 1000 },
                    key: { scale.label(for: categories[$0]) },
                    color: { categories[$0].color })
    }

    /// Profil en fonction du temps : aires mouvement/pause + courbe de fréquence cardiaque normalisée.
    static func movementRuns(from profile: [ElevationProfilePoint]) -> PDFTimeProfile {
        guard profile.count >= 2 else { return .empty }
        let stamps = profile.compactMap(\.timestamp)
        guard let t0 = stamps.first, let tLast = stamps.last, tLast > t0 else { return .empty }

        let useMinutes = tLast.timeIntervalSince(t0) < 5400
        let div = useMinutes ? 60.0 : 3600.0
        let axisLabel = useMinutes ? "Temps (min)" : "Temps (h)"
        var lastX = 0.0
        let xs = profile.map { p -> Double in
            if let t = p.timestamp { lastX = t.timeIntervalSince(t0) / div }
            return lastX
        }
        let yHi = (profile.map(\.altitude).max() ?? 1) * 1.05

        let paused = ElevationProfileBuilder.pausedSegmentFlags(profile, pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        func moving(_ i: Int) -> Bool { !(paused.indices.contains(i) && paused[i]) }

        let (samples, scale) = runs(profile: profile, xs: xs,
                                    key: { moving($0) ? "moving" : "paused" },
                                    color: { moving($0) ? .green : .gray })

        // Fréquence cardiaque
        var hr: [PDFHRSample] = []
        var ticks: [PDFHRTick] = []
        let hrs = profile.compactMap(\.heartRate).filter { $0 > 0 }
        if hrs.count >= 2, let lo = hrs.min(), let hi = hrs.max(), hi > lo {
            let span = hi - lo
            var rid = 0
            for (i, p) in profile.enumerated() where (p.heartRate ?? 0) > 0 {
                hr.append(PDFHRSample(id: rid, x: xs[i], plotY: (p.heartRate! - lo) / span * yHi))
                rid += 1
            }
            let step: Double = span > 80 ? 40 : (span > 40 ? 20 : 10)
            var bpm = (lo / step).rounded(.up) * step
            while bpm <= hi {
                ticks.append(PDFHRTick(y: (bpm - lo) / span * yHi, bpm: Int(bpm)))
                bpm += step
            }
        }

        return PDFTimeProfile(samples: samples, scale: scale, axisLabel: axisLabel, hr: hr, hrTicks: ticks, yDomainHi: yHi, available: true)
    }

    /// Construit les aires en regroupant les segments consécutifs partageant la même clé de catégorie.
    private static func runs(profile: [ElevationProfilePoint], xs: [Double], key: (Int) -> String, color: (Int) -> Color) -> ([ProfileChartSample], [String: Color]) {
        var samples: [ProfileChartSample] = []
        var scale: [String: Color] = [:]
        var rowId = 0
        var runIndex = 0
        var s = 0
        let segmentCount = profile.count - 1
        while s < segmentCount {
            let catKey = key(s)
            var e = s
            while e + 1 < segmentCount, key(e + 1) == catKey { e += 1 }
            let runKey = String(format: "%05d", runIndex)
            scale[runKey] = color(s)
            for k in s...(e + 1) {
                samples.append(ProfileChartSample(id: rowId, x: xs[k], altitude: profile[k].altitude, runKey: runKey))
                rowId += 1
            }
            runIndex += 1
            s = e + 1
        }
        return (samples, scale)
    }

    static func boundingMapRect(_ points: [TrackPoint]) -> MKMapRect? {
        var rect = MKMapRect.null
        for p in points {
            let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
            rect = rect.union(MKMapRect(origin: mp, size: MKMapSize(width: 0, height: 0)))
        }
        guard !rect.isNull, rect.size.width > 0 || rect.size.height > 0 else { return nil }
        return rect.insetBy(dx: -rect.size.width * 0.08 - 1, dy: -rect.size.height * 0.08 - 1)
    }
}

// MARK: - Page 1 : carte + statistiques

struct PDFReportPage: View {
    let activity: ActivitySummary
    let mapImage: NSImage?
    var movingTime: TimeInterval? // = montée+descente+plat (cohérent avec l'app), sinon repli sur la stat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PDFHeader(activity: activity)
            if let mapImage {
                Image(nsImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 380)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            statsSection
            if let notes = activity.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.headline)
                    Text(notes).font(.callout)
                }
            }
            Spacer(minLength: 0)
            PDFFooter()
        }
        .padding(36)
        .frame(width: 595, height: 842, alignment: .top)
        .background(Color.white)
    }

    private var statsSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            card("ruler", PDFFmt.distance(activity.distance), "Distance", .blue)
            card("arrow.up.forward", "\(Int(activity.elevationGain.rounded())) m", "Dénivelé +", .green)
            card("arrow.down.forward", "\(Int(activity.elevationLoss.rounded())) m", "Dénivelé −", .orange)
            card("clock", PDFFmt.duration(activity.duration), "Durée totale", .purple)
            card("stopwatch", PDFFmt.duration(movingTime ?? activity.movingDuration), "En mouvement", .purple)
            card("speedometer", PDFFmt.speed(activity.avgSpeed), "Vitesse moy.", .teal)
            card("gauge.with.dots.needle.67percent", PDFFmt.speed(activity.maxSpeed), "Vitesse max", .teal)
            if let hr = activity.avgHeartRate { card("heart", "\(Int(hr.rounded())) bpm", "FC moyenne", .red) }
            if let hr = activity.maxHeartRate { card("heart.fill", "\(Int(hr.rounded())) bpm", "FC max", .red) }
        }
    }

    private func card(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.95)))
    }
}

// MARK: - Page 2 : les deux profils altimétriques

struct PDFProfilesPage: View {
    let activity: ActivitySummary
    let distanceSamples: [ProfileChartSample]
    let distanceScale: [String: Color]
    let time: PDFTimeProfile
    let movingTime: TimeInterval
    let pausedTime: TimeInterval

    private var slopeScale: SlopeScale { activity.activityType.slopeScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PDFHeader(activity: activity)
            if !distanceSamples.isEmpty { distanceProfile }
            if time.available { timeProfile }
            Spacer(minLength: 0)
            PDFFooter()
        }
        .padding(36)
        .frame(width: 595, height: 842, alignment: .top)
        .background(Color.white)
    }

    private var distanceProfile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profil altimétrique — distance / pente").font(.headline)
            Chart(distanceSamples) { s in
                AreaMark(x: .value("km", s.x), y: .value("m", s.altitude), stacking: .unstacked)
                    .foregroundStyle(by: .value("Segment", s.runKey))
                    .opacity(0.7)
            }
            .chartForegroundStyleScale(domain: Array(distanceScale.keys), range: Array(distanceScale.keys).map { distanceScale[$0] ?? .clear })
            .chartLegend(.hidden)
            .chartXAxisLabel("Distance (km)")
            .chartYAxisLabel("Altitude (m)")
            .chartXScale(domain: 0...max(distanceSamples.map(\.x).max() ?? 1, 1))
            .frame(height: 200)
            slopeLegend
        }
    }

    private var timeProfile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profil altimétrique — temps / mouvement").font(.headline)
            Chart {
                ForEach(time.samples) { s in
                    AreaMark(x: .value("t", s.x), y: .value("m", s.altitude), stacking: .unstacked)
                        .foregroundStyle(by: .value("Segment", s.runKey))
                        .opacity(0.7)
                }
                ForEach(time.hr) { p in
                    LineMark(x: .value("t", p.x), y: .value("FC", p.plotY), series: .value("s", "hr"))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
            .chartForegroundStyleScale(domain: Array(time.scale.keys), range: Array(time.scale.keys).map { time.scale[$0] ?? .clear })
            .chartLegend(.hidden)
            .chartXAxisLabel(time.axisLabel)
            .chartYAxisLabel("Altitude (m)")
            .chartXScale(domain: 0...max(time.samples.map(\.x).max() ?? 1, 1))
            .chartYScale(domain: 0...max(time.yDomainHi, 1))
            .chartYAxis {
                AxisMarks(position: .leading)
                if !time.hr.isEmpty {
                    AxisMarks(position: .trailing, values: time.hrTicks.map(\.y)) { value in
                        AxisTick().foregroundStyle(.red)
                        if let y = value.as(Double.self), let tick = time.hrTicks.first(where: { abs($0.y - y) < 0.5 }) {
                            AxisValueLabel { Text("\(tick.bpm)").foregroundStyle(.red) }
                        }
                    }
                }
            }
            .frame(height: 200)
            timeLegend
        }
    }

    private var slopeLegend: some View {
        HStack(spacing: 12) {
            ForEach(slopeScale.categories, id: \.self) { cat in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(cat.color.opacity(0.7)).frame(width: 9, height: 9)
                    Text(slopeScale.label(for: cat)).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var timeLegend: some View {
        let total = movingTime + pausedTime
        func pct(_ t: TimeInterval) -> String { total > 0 ? " (\(Int((t / total * 100).rounded())) %)" : "" }
        return HStack(spacing: 14) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.7)).frame(width: 9, height: 9)
                Text("En mouvement : \(PDFFmt.duration(movingTime))\(pct(movingTime))").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.7)).frame(width: 9, height: 9)
                Text("Pause : \(PDFFmt.duration(pausedTime))\(pct(pausedTime))").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            if !time.hr.isEmpty {
                HStack(spacing: 4) {
                    Rectangle().fill(.red).frame(width: 12, height: 2)
                    Text("Fréq. cardiaque").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Éléments partagés

private struct PDFHeader: View {
    let activity: ActivitySummary
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.activityType.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.title.bold())
                Text("\(activity.activityType.displayName) · \(PDFFmt.date(activity.startDate))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct PDFFooter: View {
    var body: some View {
        Text("GPXManagement — © \(PDFFmt.year(Date())) Romain Demoustier — exporté le \(PDFFmt.date(Date()))")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private enum PDFFmt {
    static func date(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .long; f.timeStyle = .short
        return f.string(from: d)
    }
    static func year(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: d)
    }
    static func distance(_ m: Double) -> String { m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m" }
    static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }
    static func speed(_ mps: Double) -> String { String(format: "%.1f km/h", mps * 3.6) }
}
