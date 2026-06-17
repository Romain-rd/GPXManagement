import SwiftUI
import Charts
import CoreLocation
import GPXCore
import GPXRender

/// Affiche la fréquence cardiaque dans le temps d'une activité enregistrée sans position
/// (les capteurs sont stockés dans `sensorData`, hors des points de trace).
struct SensorChartView: View {
    let series: SensorSeries

    private var points: [(date: Date, value: Double)] {
        let pts = series.heartRatePoints
        guard pts.count > 1500 else { return pts }
        let step = Int((Double(pts.count) / 1500).rounded(.up))
        return stride(from: 0, to: pts.count, by: step).map { pts[$0] }
    }

    var body: some View {
        let pts = points
        let hi = (pts.map(\.value).max() ?? 1) + 6
        let lo = max(0, (pts.map(\.value).min() ?? 0) - 6)
        return Chart(pts, id: \.date) { p in
            AreaMark(x: .value("Temps", p.date), y: .value("FC", p.value))
                .foregroundStyle(.red.opacity(0.14))
            LineMark(x: .value("Temps", p.date), y: .value("FC", p.value))
                .foregroundStyle(.red)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: lo...hi)
        .chartYAxisLabel("bpm")
        .frame(height: 200)
        .clipped()
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}
