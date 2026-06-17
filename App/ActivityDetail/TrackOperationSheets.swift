import SwiftUI
import AppKit
import Charts
import MapKit
import Photos
import QuickLook
import AVFoundation
import UniformTypeIdentifiers
import GPXCore
import GPXRender
import GPXVideo
import GPXMapKit

/// Découpe une trace en deux : carte + slider de position + marqueur, puis crée deux activités dérivées.
struct SplitTrackSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var cumulative: [Double] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var fraction: Double = 0.5

    private var totalDistance: Double { cumulative.last ?? 0 }

    private var splitIndex: Int {
        guard points.count > 2, totalDistance > 0 else { return max(1, points.count / 2) }
        let target = fraction * totalDistance
        let idx = cumulative.firstIndex(where: { $0 >= target }) ?? (points.count - 1)
        return min(max(idx, 1), points.count - 2)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Découper la trace").font(.headline)
                Spacer()
            }
            .padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 4 {
                ContentUnavailableView("Trace trop courte", systemImage: "scissors",
                                       description: Text("Pas assez de points pour découper cette trace."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: coordinates).stroke(.blue, lineWidth: 3)
                    if coordinates.indices.contains(splitIndex) {
                        Annotation("Découpe", coordinate: coordinates[splitIndex]) {
                            Image(systemName: "scissors.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .background(Circle().fill(.white))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
            }
        }
        .frame(width: 660, height: 580)
        .task { await load() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Slider(value: $fraction, in: 0...1)
            HStack {
                let km = (splitIndex < cumulative.count ? cumulative[splitIndex] : 0) / 1000
                Text(String(format: "À %.2f km — point %d sur %d", km, splitIndex + 1, points.count))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Annuler") { dismiss() }
                Spacer()
                Button {
                    Task {
                        isWorking = true
                        let ok = await AppServices.shared.splitActivity(parent: activity, at: splitIndex)
                        isWorking = false
                        if ok { dismiss() }
                    }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Découper en deux", systemImage: "scissors")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding()
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id),
              let pts = try? TrackPointCodec.decode(data) else { return }
        var cum = [Double]()
        cum.reserveCapacity(pts.count)
        var total = 0.0
        for (i, p) in pts.enumerated() {
            if i > 0 { total += Self.haversine(pts[i - 1], p) }
            cum.append(total)
        }
        points = pts
        cumulative = cum
    }

    private static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

/// Simplifie une trace (Douglas-Peucker) : aperçu trace originale (gris) / simplifiée (bleu) + compteur.
struct SimplifyTrackSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var tolerance: Double = 10

    private var simplified: [TrackPoint] { TrackOperations.simplify(points: points, tolerance: tolerance) }
    private var originalCoords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    private var simplifiedCoords: [CLLocationCoordinate2D] { simplified.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    private var reduction: Int { points.isEmpty ? 0 : Int((1 - Double(simplified.count) / Double(points.count)) * 100) }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Simplifier la trace").font(.headline); Spacer() }.padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 4 {
                ContentUnavailableView("Trace trop courte", systemImage: "scribble",
                                       description: Text("Pas assez de points pour simplifier.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: originalCoords).stroke(.gray.opacity(0.5), lineWidth: 5)
                    MapPolyline(coordinates: simplifiedCoords).stroke(.blue, lineWidth: 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    HStack {
                        Text("Tolérance").foregroundStyle(.secondary)
                        Slider(value: $tolerance, in: 0...50)
                        Text(String(format: "%.0f m", tolerance)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Points : \(points.count) → \(simplified.count) (réduction \(reduction) %)")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        Button("Annuler") { dismiss() }
                        Spacer()
                        Button {
                            Task { isWorking = true; let ok = await AppServices.shared.simplifyActivity(parent: activity, tolerance: tolerance); isWorking = false; if ok { dismiss() } }
                        } label: {
                            if isWorking { ProgressView().controlSize(.small) } else { Label("Appliquer", systemImage: "scribble") }
                        }
                        .buttonStyle(.borderedProminent).disabled(isWorking)
                    }
                }
                .padding()
            }
        }
        .frame(width: 660, height: 580)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) else { return }
        points = pts
    }
}

/// Fusionne ≥ 2 traces : aperçu + ordre de raccordement + sens par trace (départ vert / arrivée rouge).
struct MergeTracksSheet: View {
    let activities: [ActivitySummary]
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id: UUID
        let summary: ActivitySummary
        let points: [TrackPoint]
        var reversed: Bool = false
        var coords: [CLLocationCoordinate2D] {
            let c = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return reversed ? c.reversed() : c
        }
        var orientedPoints: [TrackPoint] { reversed ? TrackOperations.reverse(points: points) : points }
    }

    @State private var items: [Item] = []
    @State private var isLoading = true
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Fusionner \(activities.count) traces").font(.headline); Spacer() }.padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    ForEach(items) { item in
                        MapPolyline(coordinates: item.coords).stroke(.blue, lineWidth: 2)
                        if let start = item.coords.first {
                            Annotation("", coordinate: start) { marker(.green) }
                        }
                        if let end = item.coords.last {
                            Annotation("", coordinate: end) { marker(.red) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                trackList
            }
        }
        .frame(width: 680, height: 660)
        .task { await load() }
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 11, height: 11).overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private var trackList: some View {
        VStack(spacing: 8) {
            Text("Ordre de raccordement — vert = départ, rouge = arrivée")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.summary.title).lineLimit(1)
                                Text(item.reversed ? "sens inversé" : "sens d'origine")
                                    .font(.caption2).foregroundStyle(item.reversed ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Button { items[idx].reversed.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }
                                .help("Inverser le sens de cette trace")
                            Button { move(idx, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(idx == 0)
                            Button { move(idx, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(idx == items.count - 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxHeight: 150)
            Divider()
            HStack {
                Button("Annuler") { dismiss() }
                Spacer()
                Button {
                    Task {
                        isWorking = true
                        let points = items.flatMap { $0.orientedPoints }
                        let ok = await AppServices.shared.saveMergedActivity(points: points, parents: items.map { $0.summary })
                        isWorking = false
                        if ok { dismiss() }
                    }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Label("Fusionner", systemImage: "arrow.triangle.merge") }
                }
                .buttonStyle(.borderedProminent).disabled(isWorking || items.count < 2)
            }
        }
        .padding()
    }

    private func move(_ idx: Int, by offset: Int) {
        let target = idx + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(idx, target)
    }

    private func load() async {
        defer { isLoading = false }
        let sorted = activities.sorted { $0.startDate < $1.startDate }
        var result: [Item] = []
        for a in sorted {
            if let data = try? await repository.fetchTrackData(id: a.id), let pts = try? TrackPointCodec.decode(data) {
                result.append(Item(id: a.id, summary: a, points: pts))
            }
        }
        items = result
    }
}

/// Nettoie les points aberrants : points retirés en rouge sur la carte + slider seuil de vitesse + compteur.
struct CleanTrackSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var maxSpeedKmh: Double = 200

    private var maxSpeedMps: Double { maxSpeedKmh / 3.6 }
    private var result: TrackOperations.CleanResult { TrackOperations.cleanOutliers(points: points, maxSpeed: maxSpeedMps) }
    private var coords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Nettoyer les points aberrants").font(.headline); Spacer() }.padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 3 {
                ContentUnavailableView("Trace trop courte", systemImage: "sparkles",
                                       description: Text("Pas assez de points.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 2)
                    ForEach(result.removedIndices, id: \.self) { idx in
                        if coords.indices.contains(idx) {
                            Annotation("", coordinate: coords[idx]) {
                                Circle().fill(.red).frame(width: 9, height: 9).overlay(Circle().stroke(.white, lineWidth: 1))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    HStack {
                        Text("Vitesse max").foregroundStyle(.secondary)
                        Slider(value: $maxSpeedKmh, in: 50...400)
                        Text(String(format: "%.0f km/h", maxSpeedKmh)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    HStack {
                        Text("\(result.removedIndices.count) point(s) seront retirés")
                            .font(.callout).foregroundStyle(result.removedIndices.isEmpty ? Color.secondary : Color.red)
                        Spacer()
                    }
                    HStack {
                        Button("Annuler") { dismiss() }
                        Spacer()
                        Button {
                            Task { isWorking = true; let ok = await AppServices.shared.cleanActivity(parent: activity, maxSpeed: maxSpeedMps); isWorking = false; if ok { dismiss() } }
                        } label: {
                            if isWorking { ProgressView().controlSize(.small) } else { Label("Appliquer", systemImage: "sparkles") }
                        }
                        .buttonStyle(.borderedProminent).disabled(isWorking || result.removedIndices.isEmpty)
                    }
                }
                .padding()
            }
        }
        .frame(width: 660, height: 580)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) else { return }
        points = pts
    }
}
