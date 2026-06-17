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

/// Fiche d'une étape (volet de droite) : carte zoomée, profil, stats, nom et notes éditables.
struct StageDetailView: View {
    let activity: ActivitySummary
    let stageId: UUID
    let repository: CoreDataActivityRepository

    private enum Handle { case start, end }

    @State private var fullPoints: [TrackPoint] = []
    @State private var dists: [Double] = []
    @State private var allStages: [Stage] = []
    @State private var stageIndex: Int = -1
    @State private var w0 = 0
    @State private var w1 = 0
    @State private var grabbed: Handle?
    @State private var dragCoord: CLLocationCoordinate2D?
    @State private var nameDraft = ""
    @State private var notesDraft = ""
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isRouting = false
    @State private var placingOnMap = false
    @AppStorage("mapLayerStage") private var layerRaw = MapLayer.ignScan25.rawValue
    @AppStorage("stageMapHeight") private var mapHeight: Double = 300
    @AppStorage("routeProfile") private var engineRaw = "car"

    private var layerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer.base(fromRawValue: layerRaw) }, set: { layerRaw = $0.rawValue })
    }

    private var stage: Stage? { allStages.indices.contains(stageIndex) ? allStages[stageIndex] : nil }
    private var slicePoints: [TrackPoint] { stage?.slice(of: fullPoints) ?? [] }
    private var isFirst: Bool { stageIndex == 0 }
    private var isLast: Bool { stageIndex == allStages.count - 1 }

    // Raccords hors-trace : arrivée (cette étape) et départ (= arrivée de l'étape précédente, inversée).
    private var arrivalConnector: [TrackPoint] { stage?.endConnectorPoints ?? [] }
    private var departureConnector: [TrackPoint] {
        if let pts = stage?.startConnectorPoints, !pts.isEmpty { return pts }
        // Repli (anciennes données sans raccord de départ dédié) : ligne directe du point hors-trace précédent
        // vers le point de tracé de cette étape (le plus court). « Recalculer » produit le vrai raccord routé.
        guard stageIndex > 0, let s = stage,
              let lat = allStages[stageIndex - 1].endOffTrackLatitude,
              let lon = allStages[stageIndex - 1].endOffTrackLongitude,
              fullPoints.indices.contains(s.startIndex) else { return [] }
        return [TrackPoint(latitude: lat, longitude: lon), fullPoints[s.startIndex]]
    }
    private var combinedStagePoints: [TrackPoint] { departureConnector + slicePoints + arrivalConnector }
    private var stats: ActivityStats { ActivityStatsCalculator.compute(points: combinedStagePoints) }

    private func coords(_ pts: [TrackPoint]) -> [CLLocationCoordinate2D] {
        pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
    private var offTrackMarker: CLLocationCoordinate2D? {
        guard let s = stage, let lat = s.endOffTrackLatitude, let lon = s.endOffTrackLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    private var arrivalKm: Double { ActivityStatsCalculator.compute(points: arrivalConnector).distance / 1000 }
    private var arrivalGain: Int { Int(ActivityStatsCalculator.compute(points: arrivalConnector).elevationGain.rounded()) }
    private var departureKm: Double { ActivityStatsCalculator.compute(points: departureConnector).distance / 1000 }
    private var departureGain: Int { Int(ActivityStatsCalculator.compute(points: departureConnector).elevationGain.rounded()) }

    /// Raccord de départ du **lendemain** (étape suivante) depuis le point hors-trace de cette étape — pour décider.
    private var nextDepartureConnector: [TrackPoint] {
        guard offTrackMarker != nil, stageIndex + 1 < allStages.count else { return [] }
        let pts = allStages[stageIndex + 1].startConnectorPoints
        return pts.isEmpty ? arrivalConnector.reversed() : pts
    }
    private var nextDepartureKm: Double { ActivityStatsCalculator.compute(points: nextDepartureConnector).distance / 1000 }
    private var nextDepartureGain: Int { Int(ActivityStatsCalculator.compute(points: nextDepartureConnector).elevationGain.rounded()) }

    /// Fenêtre « loupe » : étape + quelques km de contexte avant/après (borné aux étapes voisines).
    private var windowCoords: [CLLocationCoordinate2D] {
        guard w1 > w0, fullPoints.indices.contains(w0), fullPoints.indices.contains(w1) else { return [] }
        return fullPoints[w0...w1].map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
    /// Étape ramenée aux indices locaux de la fenêtre, pour colorer la portion « étape » sur la carte.
    private var windowStages: [Stage] {
        guard let s = stage, w1 > w0 else { return [] }
        return [Stage(activityId: activity.id, order: 0, name: "", startIndex: s.startIndex - w0, endIndex: s.endIndex - w0)]
    }
    private var windowDomain: ClosedRange<Double> {
        guard w1 > w0 else { return 0...1 }
        var lo = dists[w0] / 1000, hi = dists[w1] / 1000
        for p in connectorPlot { lo = Swift.min(lo, p.km); hi = Swift.max(hi, p.km) }
        return lo...max(lo + 0.01, hi)
    }

    /// Profils des raccords hors-trace, placés sur l'axe km du tracé : le départ se termine au point de
    /// rejointe (startIndex) et déborde à gauche ; l'arrivée part de endIndex et déborde à droite.
    private func cumulativeDistances(_ pts: [TrackPoint]) -> [Double] {
        var c = [Double](repeating: 0, count: pts.count)
        for i in 1..<Swift.max(pts.count, 1) { c[i] = c[i - 1] + GeoDistance.haversine(pts[i - 1], pts[i]) }
        return c
    }
    private var connectorPlot: [PlotPoint] {
        guard let s = stage, !dists.isEmpty else { return [] }
        var r: [PlotPoint] = []
        var uid = 1_000_000
        let dep = departureConnector
        if dep.count >= 2 {
            let cum = cumulativeDistances(dep); let total = cum.last ?? 0
            let baseKm = dists[s.startIndex] / 1000
            for (i, p) in dep.enumerated() {
                r.append(PlotPoint(id: uid, km: baseKm - (total - cum[i]) / 1000, alt: p.altitude ?? 0, region: "depart")); uid += 1
            }
        }
        let arr = arrivalConnector
        if arr.count >= 2 {
            let cum = cumulativeDistances(arr)
            let baseKm = dists[s.endIndex] / 1000
            for (i, p) in arr.enumerated() {
                r.append(PlotPoint(id: uid, km: baseKm + cum[i] / 1000, alt: p.altitude ?? 0, region: "arrivee")); uid += 1
            }
        }
        return r
    }

    private struct PlotPoint: Identifiable { let id: Int; let km: Double; let alt: Double; let region: String }
    /// Points du profil loupe, en 3 séries contiguës (avant / étape / après) partageant leurs points frontières
    /// → aires et lignes bien séparées (gris pour le contexte, bleu pour l'étape).
    private var windowPlot: [PlotPoint] {
        guard w1 > w0, let s = stage else { return [] }
        let a = max(w0, min(s.startIndex, w1)), b = max(a, min(s.endIndex, w1))
        let step = max(1, (w1 - w0) / 600)
        var r: [PlotPoint] = []
        var uid = 0
        func emit(_ lo: Int, _ hi: Int, _ region: String) {
            guard hi >= lo else { return }
            var lastAlt = fullPoints[lo].altitude ?? 0
            var i = lo
            while true {
                lastAlt = fullPoints[i].altitude ?? lastAlt
                r.append(PlotPoint(id: uid, km: dists[i] / 1000, alt: lastAlt, region: region)); uid += 1
                if i == hi { break }
                i = min(i + step, hi)
            }
        }
        if a > w0 { emit(w0, a, "avant") }   // inclut le point a (frontière commune avec l'étape)
        emit(a, b, "etape")
        if b < w1 { emit(b, w1, "apres") }   // inclut le point b
        return r
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stage == nil {
                ContentUnavailableView("Étape introuvable", systemImage: "flag.slash")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Text("Étape \(stageIndex + 1)").font(.title2.bold()).foregroundStyle(.secondary)
                            TextField("Nom de l'étape", text: $nameDraft)
                                .font(.title2.bold()).textFieldStyle(.plain)
                                .onSubmit { persist() }
                        }
                        if let pd = stage?.plannedDate {
                            Text(Self.ficheDateFormatter.string(from: pd)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        StageColoredMap(activityId: activity.id, activityType: activity.activityType,
                                        coords: windowCoords, stages: windowStages,
                                        connectors: [coords(departureConnector), coords(arrivalConnector), coords(nextDepartureConnector)].filter { $0.count >= 2 },
                                        highlight: dragCoord ?? offTrackMarker,
                                        onMapClick: placingOnMap ? { setArrival(to: $0); placingOnMap = false } : nil,
                                        layer: layerBinding)
                            .frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .top) {
                                if placingOnMap {
                                    Text("Cliquez sur la carte pour poser l'arrivée hors-trace")
                                        .font(.caption).padding(6)
                                        .background(.orange, in: Capsule()).foregroundStyle(.white)
                                        .padding(8)
                                }
                            }
                        DragResizeHandle { d in mapHeight = min(700, max(160, mapHeight + Double(d))) }
                        statsRow
                        departureBanner
                        loupeProfile.frame(height: 170)
                        Text("Glissez les poignées orange (début / fin) pour ajuster l'étape. La portion grise = avant/après.")
                            .font(.caption).foregroundStyle(.secondary)
                        arrivalSection
                        Text("Notes").font(.headline)
                        TextEditor(text: $notesDraft)
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    }
                    .padding()
                }
                .onDisappear { persist() }
            }
        }
        .task(id: stageId) { await load() }
    }

    private var loupeProfile: some View {
        Chart {
            ForEach(windowPlot) { p in
                AreaMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(p.region == "etape" ? Color.blue.opacity(0.22) : Color.gray.opacity(0.18))
            }
            ForEach(windowPlot) { p in
                LineMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(p.region == "etape" ? Color.blue : Color.gray)
            }
            ForEach(connectorPlot) { p in
                AreaMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(.orange.opacity(0.22))
            }
            ForEach(connectorPlot) { p in
                LineMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(.orange)
            }
            if let s = stage {
                if !isFirst { RuleMark(x: .value("km", dists[s.startIndex] / 1000)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 3)) }
                if !isLast { RuleMark(x: .value("km", dists[s.endIndex] / 1000)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 3)) }
            }
        }
        .chartXScale(domain: windowDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in onDrag(start: v.startLocation, current: v.location, proxy: proxy, geo: geo) }
                        .onEnded { _ in if grabbed != nil { grabbed = nil; dragCoord = nil; persist() } })
            }
        }
    }

    private func onDrag(start: CGPoint, current: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let s = stage, let plotFrame = proxy.plotFrame else { return }
        let rect = geo[plotFrame]
        func meters(atX x: CGFloat) -> Double? {
            let xIn = min(max(x - rect.origin.x, 0), rect.width)
            guard let km: Double = proxy.value(atX: xIn, as: Double.self) else { return nil }
            return km * 1000
        }
        if grabbed == nil {
            guard let startM = meters(atX: start.x), w1 > w0 else { return }
            let span = max(1, dists[w1] - dists[w0])
            let dStart = isFirst ? Double.greatestFiniteMagnitude : abs(dists[s.startIndex] - startM)
            let dEnd = isLast ? Double.greatestFiniteMagnitude : abs(dists[s.endIndex] - startM)
            guard min(dStart, dEnd) < span * 0.12 else { return }
            grabbed = dStart <= dEnd ? .start : .end
        }
        guard let targetM = meters(atX: current.x) else { return }
        let idx = nearestIndex(toMeters: targetM)
        switch grabbed {
        case .start where !isFirst:
            let clamped = min(max(idx, allStages[stageIndex - 1].startIndex + 1), allStages[stageIndex].endIndex - 1)
            allStages[stageIndex].startIndex = clamped
            allStages[stageIndex - 1].endIndex = clamped
            if fullPoints.indices.contains(clamped) { dragCoord = CLLocationCoordinate2D(latitude: fullPoints[clamped].latitude, longitude: fullPoints[clamped].longitude) }
        case .end where !isLast:
            let clamped = min(max(idx, allStages[stageIndex].startIndex + 1), allStages[stageIndex + 1].endIndex - 1)
            allStages[stageIndex].endIndex = clamped
            allStages[stageIndex + 1].startIndex = clamped
            if fullPoints.indices.contains(clamped) { dragCoord = CLLocationCoordinate2D(latitude: fullPoints[clamped].latitude, longitude: fullPoints[clamped].longitude) }
        default:
            break
        }
    }

    private func nearestIndex(toMeters meters: Double) -> Int {
        guard !dists.isEmpty else { return 0 }
        var lo = 0, hi = dists.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if dists[mid] < meters { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(dists[lo - 1] - meters) < abs(dists[lo] - meters) { return lo - 1 }
        return lo
    }

    private var statsRow: some View {
        HStack(spacing: 22) {
            stat("Distance", String(format: "%.1f km", stats.distance / 1000))
            stat("D+", String(format: "+%d m", Int(stats.elevationGain.rounded())))
            stat("D−", String(format: "−%d m", Int(stats.elevationLoss.rounded())))
            if stats.movingDuration > 0 { stat("Durée", Self.clock(stats.movingDuration)) }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded()); return String(format: "%dh%02d", m / 60, m % 60)
    }

    private static let ficheDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .full; return f
    }()

    @ViewBuilder private var departureBanner: some View {
        if !departureConnector.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Départ hors-trace", systemImage: "arrow.up.forward").font(.headline)
                    Spacer()
                    if isRouting { ProgressView().controlSize(.small) }
                    Button("Recalculer") { recomputeDeparture() }.controlSize(.small)
                }
                Text(String(format: "Raccord de départ : +%.1f km · +%d m D+ — plus court chemin pour rejoindre la trace depuis l'arrivée de l'étape précédente.", departureKm, departureGain))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.10)))
        }
    }

    private func recomputeDeparture() {
        guard stageIndex > 0,
              let lat = allStages[stageIndex - 1].endOffTrackLatitude,
              let lon = allStages[stageIndex - 1].endOffTrackLongitude else { return }
        let p = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let leave = allStages[stageIndex - 1].endIndex
        isRouting = true
        Task {
            let rejoin = nearestTrackIndex(to: p, in: leave...max(leave, allStages[stageIndex].endIndex - 1))
            let rejoinCoord = CLLocationCoordinate2D(latitude: fullPoints[rejoin].latitude, longitude: fullPoints[rejoin].longitude)
            let departure = await AppServices.shared.buildConnector(from: p, to: rejoinCoord)
            allStages[stageIndex].startIndex = rejoin
            allStages[stageIndex].startConnectorData = try? TrackPointCodec.encode(departure)
            isRouting = false
            persist()
        }
    }

    private var arrivalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Arrivée hors-trace").font(.headline)
                Spacer()
                if isRouting { ProgressView().controlSize(.small) }
                if offTrackMarker != nil {
                    Button("Retirer", role: .destructive) { clearArrival() }.controlSize(.small)
                }
            }
            if offTrackMarker == nil {
                Text("Placez l'arrivée hors du tracé (ex. refuge) : le raccord est calculé et compté dans l'étape.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Arrivée du jour : +%.1f km · +%d m D+", arrivalKm, arrivalGain))
                    if stageIndex + 1 < allStages.count {
                        Text(String(format: "Départ du lendemain : +%.1f km · +%d m D+", nextDepartureKm, nextDepartureGain))
                        Text(String(format: "Coût total du détour : +%.1f km · +%d m D+", arrivalKm + nextDepartureKm, arrivalGain + nextDepartureGain))
                            .fontWeight(.semibold)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Rechercher un lieu (refuge, village…)", text: $searchText)
                    .textFieldStyle(.roundedBorder).onSubmit { runSearch() }
                Button("Rechercher") { runSearch() }
                Button(placingOnMap ? "Annuler" : "Choisir sur la carte") { placingOnMap.toggle() }
            }
            HStack(spacing: 8) {
                Text("Itinéraire").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $engineRaw) {
                    ForEach(RouteProfile.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            }
            ForEach(searchResults, id: \.self) { item in
                Button { setArrival(to: item.placemark.coordinate) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle").foregroundStyle(.orange)
                        Text(item.name ?? "Lieu").lineLimit(1)
                        Spacer()
                        if let t = item.placemark.title { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let s = stage, fullPoints.indices.contains(s.endIndex) {
            let c = CLLocationCoordinate2D(latitude: fullPoints[s.endIndex].latitude, longitude: fullPoints[s.endIndex].longitude)
            request.region = MKCoordinateRegion(center: c, latitudinalMeters: 40000, longitudinalMeters: 40000)
        }
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            searchResults = response?.mapItems ?? []
        }
    }

    private func setArrival(to point: CLLocationCoordinate2D) {
        guard let s = stage, !fullPoints.isEmpty else { return }
        searchResults = []
        searchText = ""
        placingOnMap = false
        isRouting = true
        let boundary = s.endIndex // jonction d'origine entre cette étape et la suivante
        let hasNext = stageIndex + 1 < allStages.count
        let nextEnd = hasNext ? allStages[stageIndex + 1].endIndex : 0
        Task {
            // Arrivée : on quitte la trace au point le plus proche de P **dans cette étape** (le plus court).
            let leave = nearestTrackIndex(to: point, in: (s.startIndex + 1)...boundary)
            let leaveCoord = CLLocationCoordinate2D(latitude: fullPoints[leave].latitude, longitude: fullPoints[leave].longitude)
            let arrival = await AppServices.shared.buildConnector(from: leaveCoord, to: point)
            allStages[stageIndex].endIndex = leave
            allStages[stageIndex].endOffTrackLatitude = point.latitude
            allStages[stageIndex].endOffTrackLongitude = point.longitude
            allStages[stageIndex].endConnectorData = try? TrackPointCodec.encode(arrival)
            // Départ du lendemain : on rejoint la trace au point le plus proche de P **dans l'étape suivante** (le plus court).
            if hasNext, boundary <= nextEnd - 1 {
                let rejoin = nearestTrackIndex(to: point, in: boundary...(nextEnd - 1))
                let rejoinCoord = CLLocationCoordinate2D(latitude: fullPoints[rejoin].latitude, longitude: fullPoints[rejoin].longitude)
                let departure = await AppServices.shared.buildConnector(from: point, to: rejoinCoord)
                allStages[stageIndex + 1].startIndex = rejoin
                allStages[stageIndex + 1].startConnectorData = try? TrackPointCodec.encode(departure)
            }
            isRouting = false
            persist()
        }
    }

    private func clearArrival() {
        guard stageIndex >= 0, let s = stage else { return }
        allStages[stageIndex].endOffTrackLatitude = nil
        allStages[stageIndex].endOffTrackLongitude = nil
        allStages[stageIndex].endConnectorData = nil
        if stageIndex + 1 < allStages.count {
            allStages[stageIndex + 1].startConnectorData = nil
            allStages[stageIndex + 1].startIndex = s.endIndex // re-contigu avec la fin de cette étape
        }
        persist()
    }

    private func nearestTrackIndex(to p: CLLocationCoordinate2D, in range: ClosedRange<Int>) -> Int {
        var best = range.lowerBound
        var bestDist = Double.greatestFiniteMagnitude
        for i in range where fullPoints.indices.contains(i) {
            let dLat = fullPoints[i].latitude - p.latitude
            let dLon = fullPoints[i].longitude - p.longitude
            let d = dLat * dLat + dLon * dLon
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Sauvegarde ciblée : la fiche ne met à jour QUE ses propres étapes (courante + voisines modifiées),
    /// sans réécrire toute la liste — évite d'écraser les changements de structure faits dans l'aperçu (suppression…).
    private func persist() {
        guard stageIndex >= 0 else { return }
        let trimmed = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        allStages[stageIndex].name = nameDraft
        allStages[stageIndex].notes = trimmed.isEmpty ? nil : trimmed
        // Source de vérité = les stops : on réenregistre tout le parcours pour synchroniser les frontières d'étapes.
        let snapshot = allStages
        let pts = fullPoints
        Task {
            if let updated = try? await repository.saveStagedRoute(activityId: activity.id, stages: snapshot, points: pts) {
                await MainActor.run { if updated.count == allStages.count { allStages = updated } }
            }
            AppServices.shared.libraryRevision += 1
        }
    }

    private func load() async {
        defer { isLoading = false }
        var pts: [TrackPoint] = []
        if let data = try? await repository.fetchTrackData(id: activity.id), let p = try? TrackPointCodec.decode(data) {
            pts = p
        }
        let stages = ((try? await repository.fetchStagesResolved(activityId: activity.id, points: pts)) ?? []).sorted { $0.order < $1.order }
        guard let idx = stages.firstIndex(where: { $0.id == stageId }) else { allStages = []; stageIndex = -1; return }
        var d: [Double] = []
        if !pts.isEmpty {
            fullPoints = pts
            d = [Double](repeating: 0, count: pts.count)
            for i in 1..<max(pts.count, 1) { d[i] = d[i - 1] + GeoDistance.haversine(pts[i - 1], pts[i]) }
        }
        dists = d
        allStages = stages
        stageIndex = idx
        nameDraft = stages[idx].name
        notesDraft = stages[idx].notes ?? ""
        // Fenêtre loupe : ~3 km de contexte de part et d'autre, borné aux étapes voisines.
        if !d.isEmpty {
            let s = stages[idx]
            let contextM = 3000.0
            let prevStart = idx > 0 ? stages[idx - 1].startIndex : 0
            let nextEnd = idx < stages.count - 1 ? stages[idx + 1].endIndex : d.count - 1
            w0 = max(prevStart, indexAtMeters(d[s.startIndex] - contextM, in: d))
            w1 = min(nextEnd, indexAtMeters(d[s.endIndex] + contextM, in: d))
        }
    }

    private func indexAtMeters(_ meters: Double, in d: [Double]) -> Int {
        guard !d.isEmpty else { return 0 }
        var lo = 0, hi = d.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if d[mid] < meters { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}
