import SwiftUI
import Charts
import AppKit
import MapKit
import GPXCore
import GPXMapKit

enum PDFReportError: Error, LocalizedError {
    case noTrackData
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noTrackData:  return "Cette activité ne contient pas de trace."
        case .renderFailed: return "Échec de la génération du PDF."
        }
    }
}

@MainActor
enum PDFReportRenderer {
    // A4 portrait en points (72 dpi).
    private static let pageSize = CGSize(width: 595, height: 842)

    static func render(activity: ActivitySummary, repository: CoreDataActivityRepository, layer: MapLayer) async throws -> Data {
        guard let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty else {
            throw PDFReportError.noTrackData
        }
        let points = try TrackPointCodec.decode(data)

        // Carte de la trace (cadrée sur le parcours).
        var mapImage: NSImage?
        if let mapRect = boundingMapRect(points) {
            let overlay = TrackOverlayInput(activityId: activity.id, activityType: activity.activityType, coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
            if let png = try? await MapImageExporter.renderPNG(layer: layer, mapRect: mapRect, tracks: [overlay]) {
                mapImage = NSImage(data: png)
            }
        }

        let profile = ElevationProfileBuilder.build(points: points)
        let samples = profile.enumerated().map { idx, p in
            ProfileChartSample(id: idx, distanceKm: p.distanceFromStart / 1000, altitude: p.altitude, category: SlopeCategory.category(for: p.slope))
        }

        let page = PDFReportPage(activity: activity, mapImage: mapImage, samples: samples)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(pageSize)

        let pdfData = NSMutableData()
        var produced = false
        renderer.render { size, renderInContext in
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return }
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            pdfContext.beginPDFPage(nil)
            renderInContext(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
            produced = true
        }
        guard produced, pdfData.length > 0 else { throw PDFReportError.renderFailed }
        return pdfData as Data
    }

    private static func boundingMapRect(_ points: [TrackPoint]) -> MKMapRect? {
        var rect = MKMapRect.null
        for p in points {
            let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
            rect = rect.union(MKMapRect(origin: mp, size: MKMapSize(width: 0, height: 0)))
        }
        guard !rect.isNull, rect.size.width > 0 || rect.size.height > 0 else { return nil }
        return rect.insetBy(dx: -rect.size.width * 0.08 - 1, dy: -rect.size.height * 0.08 - 1)
    }
}

struct ProfileChartSample: Identifiable {
    let id: Int
    let distanceKm: Double
    let altitude: Double
    let category: SlopeCategory
}

struct PDFReportPage: View {
    let activity: ActivitySummary
    let mapImage: NSImage?
    let samples: [ProfileChartSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            mapSection
            profileSection
            statsSection
            if let notes = activity.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.headline)
                    Text(notes).font(.callout)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(36)
        .frame(width: 595, height: 842, alignment: .top)
        .background(Color.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.activityType.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.title.bold())
                Text("\(activity.activityType.displayName) · \(Self.formatDate(activity.startDate))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var mapSection: some View {
        if let mapImage {
            Image(nsImage: mapImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 360)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profil altimétrique").font(.headline)
                Chart(samples) { s in
                    AreaMark(x: .value("km", s.distanceKm), y: .value("m", s.altitude))
                        .foregroundStyle(by: .value("Pente", s.category.label))
                        .opacity(0.7)
                }
                .chartForegroundStyleScale([
                    SlopeCategory.gentle.label:   SlopeCategory.gentle.color,
                    SlopeCategory.moderate.label: SlopeCategory.moderate.color,
                    SlopeCategory.steep.label:    SlopeCategory.steep.color,
                    SlopeCategory.veryStep.label: SlopeCategory.veryStep.color,
                    SlopeCategory.descent.label:  SlopeCategory.descent.color
                ])
                .chartLegend(.hidden)
                .frame(height: 130)
            }
        }
    }

    private var statsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
            GridRow {
                stat("Distance", Self.distance(activity.distance))
                stat("Durée", Self.duration(activity.duration))
                stat("En mouvement", Self.duration(activity.movingDuration))
            }
            GridRow {
                stat("Dénivelé +", "\(Int(activity.elevationGain.rounded())) m")
                stat("Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m")
                stat("Vitesse moy.", Self.speed(activity.avgSpeed))
            }
            GridRow {
                stat("Vitesse max", Self.speed(activity.maxSpeed))
                if let hr = activity.avgHeartRate { stat("FC moy.", "\(Int(hr.rounded())) bpm") } else { Color.clear }
                if let hr = activity.maxHeartRate { stat("FC max", "\(Int(hr.rounded())) bpm") } else { Color.clear }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
    }

    private var footer: some View {
        Text("GPXManagement — exporté le \(Self.formatDate(Date()))")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .long; f.timeStyle = .short
        return f.string(from: d)
    }
    private static func distance(_ m: Double) -> String { m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m" }
    private static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }
    private static func speed(_ mps: Double) -> String { String(format: "%.1f km/h", mps * 3.6) }
}
