import SwiftUI
import Charts
import GPXCore

struct StatisticsView: View {
    let activities: [ActivitySummary]        // inspecteur : la sélection, ou la liste filtrée si rien n'est sélectionné
    let annualActivities: [ActivitySummary]  // bilan annuel : la liste filtrée, indépendante de la sélection
    let selectionActive: Bool
    var onOpenActivity: (UUID) -> Void = { _ in }

    enum Mode: String, CaseIterable, Identifiable {
        case selection, annual
        var id: String { rawValue }
        var label: String { self == .selection ? "Sélection" : "Bilan annuel" }
    }

    @State private var mode: Mode = .selection
    @State private var selectedMetric: StatsMetric = .distance

    private var selStats: SelectionStats { SelectionStats.compute(activities) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBar
                switch mode {
                case .selection: selectionContent
                case .annual:    annualContent
                }
            }
            .padding()
        }
        .navigationTitle("Statistiques")
    }

    private var headerBar: some View {
        HStack(spacing: 16) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer()

            Picker("", selection: $selectedMetric) {
                Text("Distance").tag(StatsMetric.distance)
                Text("Dénivelé +").tag(StatsMetric.elevationGain)
                Text("Temps").tag(StatsMetric.duration)
                Text("Sorties").tag(StatsMetric.count)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
        }
    }

    // MARK: - Mode sélection

    @ViewBuilder
    private var selectionContent: some View {
        if activities.isEmpty {
            ContentUnavailableView("Aucune trace", systemImage: "tray",
                                   description: Text("Sélectionnez des traces dans la liste, ou choisissez une catégorie dans la barre latérale."))
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            selectionHeader
            primaryKPIs
            derivedChips
            Divider()
            if selectionBreakdown.count > 1 {
                breakdownChart(entries: selectionBreakdown, title: "Ventilation par activité")
                Divider()
            }
            distributionChart
            Divider()
            recordsSection
            Divider()
            selectionCumulativeChart
        }
    }

    private var selectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectionActive ? "\(selStats.count) sorties sélectionnées" : "\(selStats.count) sorties affichées")
                .font(.title3.bold())
            if let from = selStats.firstDate, let to = selStats.lastDate {
                Text(Self.rangeLabel(from, to)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var primaryKPIs: some View {
        HStack(spacing: 12) {
            kpiCard(title: "Distance", value: Self.formatDistance(selStats.totalDistance), trend: nil)
            kpiCard(title: "Dénivelé +", value: "\(Int(selStats.totalElevationGain.rounded())) m", trend: nil)
            kpiCard(title: "Temps mvt", value: Self.formatDuration(selStats.totalMovingDuration), trend: nil)
            kpiCard(title: "Sorties", value: String(selStats.count), trend: nil)
        }
    }

    private var derivedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                statChip("Distance moy.", Self.formatDistance(selStats.avgDistance))
                statChip("Plus longue", Self.formatDistance(selStats.maxDistance))
                statChip("D+ max", "\(Int(selStats.maxElevationGain.rounded())) m")
                statChip("Pente max", String(format: "%.0f %%", selStats.maxSlope))
                statChip("Vitesse max", String(format: "%.1f km/h", selStats.maxSpeed * 3.6))
            }
        }
    }

    private func statChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().bold())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    // Histogramme de répartition selon la métrique (la métrique « Sorties » retombe sur la distance).
    private var distributionMetric: StatsMetric { selectedMetric == .count ? .distance : selectedMetric }

    private var distributionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Répartition — \(Self.metricLabel(distributionMetric))").font(.headline)
            Chart(distributionBins, id: \.label) { bin in
                BarMark(x: .value("Tranche", bin.label), y: .value("Sorties", bin.count))
                    .foregroundStyle(.tint)
                    .annotation(position: .top) { Text("\(bin.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .frame(height: 180)
        }
    }

    private var distributionBins: [(label: String, count: Int, order: Int)] {
        let width = Self.bucketWidth(distributionMetric)
        var bins: [Int: Int] = [:]
        for a in activities {
            let idx = Int(distributionMetric.value(for: a) / width)
            bins[idx, default: 0] += 1
        }
        return bins.keys.sorted().map { idx in
            (Self.bucketLabel(idx: idx, width: width, metric: distributionMetric), bins[idx] ?? 0, idx)
        }
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Records de la sélection").font(.headline)
            VStack(spacing: 0) {
                recordRow("Plus longue", systemImage: "arrow.left.and.right",
                          activity: activities.max { $0.distance < $1.distance },
                          value: { Self.formatDistance($0.distance) })
                recordRow("Plus de dénivelé", systemImage: "arrow.up.forward",
                          activity: activities.max { $0.elevationGain < $1.elevationGain },
                          value: { "\(Int($0.elevationGain.rounded())) m" })
                recordRow("Plus raide", systemImage: "triangle",
                          activity: activities.max { $0.maxSlope < $1.maxSlope },
                          value: { String(format: "%.0f %%", $0.maxSlope) })
                recordRow("Plus rapide (moy.)", systemImage: "gauge.with.dots.needle.67percent",
                          activity: activities.max { $0.avgSpeed < $1.avgSpeed },
                          value: { String(format: "%.1f km/h", $0.avgSpeed * 3.6) })
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        }
    }

    @ViewBuilder
    private func recordRow(_ title: String, systemImage: String, activity: ActivitySummary?, value: (ActivitySummary) -> String) -> some View {
        if let activity {
            Button {
                onOpenActivity(activity.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage).foregroundStyle(.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.caption).foregroundStyle(.secondary)
                        Text(activity.title).font(.callout).lineLimit(1)
                    }
                    Spacer()
                    Text(value(activity)).font(.callout.monospacedDigit().bold())
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var selectionCumulativeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cumul sur la période").font(.headline)
            Chart(selectionCumulative, id: \.date) { p in
                LineMark(x: .value("Date", p.date), y: .value(Self.metricLabel(selectedMetric), p.value))
                    .foregroundStyle(.tint)
                AreaMark(x: .value("Date", p.date), y: .value(Self.metricLabel(selectedMetric), p.value))
                    .foregroundStyle(.tint.opacity(0.12))
            }
            .frame(height: 200)
        }
    }

    private var selectionCumulative: [(date: Date, value: Double)] {
        let sorted = activities.sorted { $0.startDate < $1.startDate }
        var cumulative: Double = 0
        return sorted.map { a in
            cumulative += selectedMetric.value(for: a)
            return (a.startDate, cumulative)
        }
    }

    // MARK: - Mode bilan annuel

    @ViewBuilder
    private var annualContent: some View {
        if annualActivities.isEmpty {
            ContentUnavailableView("Aucune activité", systemImage: "tray", description: Text("Aucune donnée à afficher."))
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            annualKPIs
            Divider()
            if annualBreakdown.count > 1 {
                breakdownChart(entries: annualBreakdown, title: "Ventilation par activité — toutes années")
                Divider()
            }
            cumulativeChart
            Divider()
            yearGrid
        }
    }

    private var availableYears: [Int] {
        Set(annualActivities.map { Calendar.iso8601UTC.component(.year, from: $0.startDate) }).sorted(by: >)
    }

    private var currentYear: Int { Calendar.iso8601UTC.component(.year, from: Date()) }

    private var currentResult: StatsResult {
        StatsAggregator.compute(activities: annualActivities, query: StatsQuery(period: .year(currentYear)))
    }

    private var previousResult: StatsResult {
        StatsAggregator.compute(activities: annualActivities, query: StatsQuery(period: .year(currentYear - 1)))
    }

    private var annualKPIs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Année en cours — \(String(currentYear))").font(.headline)
            annualKPICards
        }
    }

    private var annualKPICards: some View {
        HStack(spacing: 12) {
            kpiCard(title: "Distance", value: Self.formatDistance(currentResult.totalDistance), trend: trend(currentResult.totalDistance, previousResult.totalDistance))
            kpiCard(title: "Dénivelé +", value: "\(Int(currentResult.totalElevationGain.rounded())) m", trend: trend(currentResult.totalElevationGain, previousResult.totalElevationGain))
            kpiCard(title: "Temps", value: Self.formatDuration(currentResult.totalDuration), trend: trend(currentResult.totalDuration, previousResult.totalDuration))
            kpiCard(title: "Sorties", value: String(currentResult.activityCount), trend: trend(Double(currentResult.activityCount), Double(previousResult.activityCount)))
        }
    }

    private var cumulativeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cumul par année — \(Self.metricLabel(selectedMetric))").font(.headline)
            Chart {
                ForEach(availableYears.reversed(), id: \.self) { year in
                    ForEach(yearCumulative(year)) { p in
                        LineMark(x: .value("Jour", p.dayOfYear), y: .value(selectedMetric.rawValue, p.cumulativeValue), series: .value("Année", String(year)))
                            .foregroundStyle(by: .value("Année", String(year)))
                            .lineStyle(StrokeStyle(lineWidth: year == currentYear ? 2.5 : 1.5))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335]) { value in
                    AxisValueLabel(Self.monthLabel(forDayOfYear: value.as(Int.self) ?? 1))
                }
            }
            .frame(height: 260)
        }
    }

    // L'année en cours s'arrête à aujourd'hui (sinon la courbe file à plat jusqu'en décembre).
    private func yearCumulative(_ year: Int) -> [CumulativePoint] {
        let points = YearComparisonBuilder.cumulative(activities: annualActivities, year: year, metric: selectedMetric)
        guard year == currentYear else { return points }
        let today = Calendar.iso8601UTC.ordinality(of: .day, in: .year, for: Date()) ?? points.count
        return points.filter { $0.dayOfYear <= today }
    }

    private var yearGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tableau croisé — \(Self.gridMetricLabel(selectedMetric)) par mois").font(.headline)
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("Année").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        ForEach(1...12, id: \.self) { month in
                            Text(Self.shortMonth(month)).foregroundStyle(.secondary).frame(width: 48)
                        }
                        Text("Total").foregroundStyle(.secondary).frame(width: 56)
                    }
                    Divider().gridCellColumns(14)
                    ForEach(availableYears, id: \.self) { year in
                        let result = StatsAggregator.compute(activities: annualActivities, query: StatsQuery(period: .year(year)))
                        GridRow {
                            Text(String(year)).gridColumnAlignment(.leading).font(.callout.monospacedDigit())
                            ForEach(1...12, id: \.self) { month in
                                let value = Self.monthValue(result.byMonth?[month], metric: selectedMetric)
                                Text(value.isEmpty ? "—" : value)
                                    .frame(width: 48)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                            }
                            Text(Self.totalValue(result, metric: selectedMetric))
                                .frame(width: 56)
                                .font(.caption.monospacedDigit().bold())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Ventilation partagée

    private struct BreakdownEntry { let type: ActivityType; let value: Double; let formatted: String }

    private func breakdownChart(entries: [BreakdownEntry], title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart {
                ForEach(entries, id: \.type) { entry in
                    BarMark(x: .value("Valeur", entry.value), y: .value("Activité", entry.type.displayName))
                        .foregroundStyle(by: .value("Activité", entry.type.displayName))
                        .annotation(position: .trailing) {
                            Text(entry.formatted).font(.caption.monospacedDigit())
                        }
                }
            }
            .frame(height: max(120, CGFloat(entries.count) * 32))
        }
    }

    private var selectionBreakdown: [BreakdownEntry] { breakdownEntries(from: selStats.byActivityType) }
    private var annualBreakdown: [BreakdownEntry] { breakdownEntries(from: SelectionStats.compute(annualActivities).byActivityType) }

    private func breakdownEntries(from byType: [ActivityType: TypeBreakdown]) -> [BreakdownEntry] {
        byType.map { (type, bd) in
            let val: Double
            let formatted: String
            switch selectedMetric {
            case .distance:      val = bd.totalDistance;      formatted = Self.formatDistance(val)
            case .elevationGain: val = bd.totalElevationGain; formatted = "\(Int(val.rounded())) m"
            case .duration:      val = bd.totalDuration;      formatted = Self.formatDuration(val)
            case .count:         val = Double(bd.activityCount); formatted = "\(Int(val))"
            }
            return BreakdownEntry(type: type, value: val, formatted: formatted)
        }
        .sorted { $0.value > $1.value }
    }

    // MARK: - Cartes & helpers

    private func kpiCard(title: String, value: String, trend: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.monospacedDigit().bold())
            if let trend, trend.isFinite {
                let pct = (trend * 100).rounded()
                Label("\(pct >= 0 ? "+" : "")\(Int(pct)) % vs \(String(currentYear - 1))", systemImage: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(pct >= 0 ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private static func monthValue(_ bd: MonthBreakdown?, metric: StatsMetric) -> String {
        guard let bd, bd.activityCount > 0 else { return "" }
        switch metric {
        case .distance:      return String(format: "%.0f", bd.totalDistance / 1000)
        case .elevationGain: return "\(Int(bd.totalElevationGain.rounded()))"
        case .duration:      return formatDuration(bd.totalDuration)
        case .count:         return "\(bd.activityCount)"
        }
    }

    private static func totalValue(_ r: StatsResult, metric: StatsMetric) -> String {
        switch metric {
        case .distance:      return String(format: "%.0f", r.totalDistance / 1000)
        case .elevationGain: return "\(Int(r.totalElevationGain.rounded()))"
        case .duration:      return formatDuration(r.totalDuration)
        case .count:         return "\(r.activityCount)"
        }
    }

    private static func gridMetricLabel(_ m: StatsMetric) -> String {
        switch m {
        case .distance:      return "Distance (km)"
        case .elevationGain: return "Dénivelé + (m)"
        case .duration:      return "Temps"
        case .count:         return "Sorties"
        }
    }

    private func trend(_ current: Double, _ previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    private static func bucketWidth(_ m: StatsMetric) -> Double {
        switch m {
        case .distance:      return 10_000
        case .elevationGain: return 250
        case .duration:      return 3_600
        case .count:         return 10_000
        }
    }

    private static func bucketLabel(idx: Int, width: Double, metric: StatsMetric) -> String {
        let lo = Double(idx) * width
        let hi = lo + width
        switch metric {
        case .distance:      return "\(Int(lo / 1000))–\(Int(hi / 1000))"
        case .elevationGain: return "\(Int(lo))–\(Int(hi))"
        case .duration:      return "\(Int(lo / 3600))–\(Int(hi / 3600))h"
        case .count:         return "\(Int(lo / 1000))–\(Int(hi / 1000))"
        }
    }

    private static func metricLabel(_ m: StatsMetric) -> String {
        switch m {
        case .distance:      return "Distance"
        case .elevationGain: return "Dénivelé +"
        case .duration:      return "Temps"
        case .count:         return "Sorties"
        }
    }

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static func rangeLabel(_ from: Date, _ to: Date) -> String {
        if Calendar.iso8601UTC.isDate(from, inSameDayAs: to) { return rangeFormatter.string(from: from) }
        return "\(rangeFormatter.string(from: from)) → \(rangeFormatter.string(from: to))"
    }

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }

    private static func formatDuration(_ s: Double) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    private static func shortMonth(_ month: Int) -> String {
        let names = ["jan", "fév", "mar", "avr", "mai", "jui", "jul", "aoû", "sep", "oct", "nov", "déc"]
        return month >= 1 && month <= 12 ? names[month - 1] : ""
    }

    private static func monthLabel(forDayOfYear day: Int) -> String {
        let bounds = [1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335]
        for (idx, b) in bounds.enumerated() where day == b {
            return shortMonth(idx + 1)
        }
        return ""
    }
}
