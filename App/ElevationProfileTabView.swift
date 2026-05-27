import SwiftUI
import Charts
import GPXCore

extension SlopeCategory {
    var label: String {
        switch self {
        case .gentle:   return "0–4 %"
        case .moderate: return "4–8 %"
        case .steep:    return "8–12 %"
        case .veryStep: return "> 12 %"
        case .descent:  return "Descente"
        }
    }

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

private struct ProfileSample: Identifiable {
    let id: Int
    let distanceKm: Double
    let altitude: Double
    let slope: Double
    let category: SlopeCategory
}

struct ElevationProfileTabView: View {
    let activityId: UUID
    let repository: CoreDataActivityRepository

    @State private var samples: [ProfileSample] = []
    @State private var altMin: Double = 0
    @State private var altMax: Double = 0
    @State private var dPlus: Double = 0
    @State private var dMinus: Double = 0
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Chargement du profil…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Profil indisponible", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if samples.isEmpty {
                ContentUnavailableView("Pas d'altitude", systemImage: "chart.xyaxis.line", description: Text("La trace ne contient pas de données d'altitude."))
            } else {
                profileContent
            }
        }
        .task(id: activityId) { await load() }
    }

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            statsBar
                .padding(.horizontal)
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)
        }
    }

    private var statsBar: some View {
        HStack(spacing: 24) {
            statBlock("Distance", String(format: "%.2f km", samples.last?.distanceKm ?? 0))
            statBlock("Alt min", "\(Int(altMin.rounded())) m")
            statBlock("Alt max", "\(Int(altMax.rounded())) m")
            statBlock("D+", "\(Int(dPlus.rounded())) m")
            statBlock("D−", "\(Int(dMinus.rounded())) m")
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
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Distance", sample.distanceKm),
                    y: .value("Altitude", sample.altitude)
                )
                .foregroundStyle(by: .value("Pente", sample.category.label))
                .opacity(0.65)
            }
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Distance", sample.distanceKm),
                    y: .value("Altitude", sample.altitude)
                )
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        .chartForegroundStyleScale([
            SlopeCategory.gentle.label:   SlopeCategory.gentle.color,
            SlopeCategory.moderate.label: SlopeCategory.moderate.color,
            SlopeCategory.steep.label:    SlopeCategory.steep.color,
            SlopeCategory.veryStep.label: SlopeCategory.veryStep.color,
            SlopeCategory.descent.label:  SlopeCategory.descent.color
        ])
        .chartXAxisLabel("Distance (km)")
        .chartYAxisLabel("Altitude (m)")
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            guard let data = try await repository.fetchTrackData(id: activityId), !data.isEmpty else {
                samples = []
                isLoading = false
                return
            }
            let trackPoints = try TrackPointCodec.decode(data)
            let raw = ElevationProfileBuilder.build(points: trackPoints)
            let trimmed = ElevationProfileBuilder.decimate(raw, tolerance: 1.0, maxPoints: 5_000)
            let summary = computeAltStats(profile: raw)

            samples = trimmed.enumerated().map { idx, p in
                ProfileSample(
                    id: idx,
                    distanceKm: p.distanceFromStart / 1000,
                    altitude: p.altitude,
                    slope: p.slope,
                    category: SlopeCategory.category(for: p.slope)
                )
            }
            altMin = summary.altMin
            altMax = summary.altMax
            dPlus = summary.dPlus
            dMinus = summary.dMinus
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
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
