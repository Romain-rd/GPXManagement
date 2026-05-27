import SwiftUI
import Charts
import GPXCore

struct StatisticsView: View {
    let activities: [ActivitySummary]

    @State private var selectedYear: Int
    @State private var selectedTypes: Set<ActivityType> = []
    @State private var selectedMetric: StatsMetric = .distance

    init(activities: [ActivitySummary]) {
        self.activities = activities
        let years = Set(activities.map { Calendar.iso8601UTC.component(.year, from: $0.startDate) })
        self._selectedYear = State(initialValue: years.max() ?? Calendar.iso8601UTC.component(.year, from: Date()))
    }

    private var availableYears: [Int] {
        let years = Set(activities.map { Calendar.iso8601UTC.component(.year, from: $0.startDate) })
        return years.sorted(by: >)
    }

    private var currentResult: StatsResult {
        StatsAggregator.compute(activities: activities, query: StatsQuery(period: .year(selectedYear), activityTypes: selectedTypes.isEmpty ? nil : selectedTypes))
    }

    private var previousResult: StatsResult {
        StatsAggregator.compute(activities: activities, query: StatsQuery(period: .year(selectedYear - 1), activityTypes: selectedTypes.isEmpty ? nil : selectedTypes))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filtersBar
                if currentResult.activityCount == 0 {
                    ContentUnavailableView("Aucune activité", systemImage: "tray", description: Text("Aucune donnée pour les filtres sélectionnés."))
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    kpiCards
                    Divider()
                    breakdownChart
                    Divider()
                    cumulativeChart
                    Divider()
                    monthGrid
                }
            }
            .padding()
        }
        .navigationTitle("Statistiques")
    }

    private var filtersBar: some View {
        HStack(spacing: 16) {
            Picker("Année", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { y in
                    Text(String(y)).tag(y)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)

            Menu {
                Toggle("Toutes activités", isOn: Binding(
                    get: { selectedTypes.isEmpty },
                    set: { if $0 { selectedTypes.removeAll() } }
                ))
                Divider()
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Toggle(type.displayName, isOn: Binding(
                        get: { selectedTypes.contains(type) },
                        set: { if $0 { selectedTypes.insert(type) } else { selectedTypes.remove(type) } }
                    ))
                }
            } label: {
                Label(selectedTypes.isEmpty ? "Toutes activités" : "\(selectedTypes.count) activité(s)", systemImage: "line.3.horizontal.decrease.circle")
            }

            Spacer()
            Picker("Métrique", selection: $selectedMetric) {
                Text("Distance").tag(StatsMetric.distance)
                Text("Dénivelé +").tag(StatsMetric.elevationGain)
                Text("Temps").tag(StatsMetric.duration)
                Text("Sorties").tag(StatsMetric.count)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }

    private var kpiCards: some View {
        HStack(spacing: 12) {
            kpiCard(title: "Distance", value: Self.formatDistance(currentResult.totalDistance), trend: trend(currentResult.totalDistance, previousResult.totalDistance))
            kpiCard(title: "Dénivelé +", value: "\(Int(currentResult.totalElevationGain.rounded())) m", trend: trend(currentResult.totalElevationGain, previousResult.totalElevationGain))
            kpiCard(title: "Temps", value: Self.formatDuration(currentResult.totalDuration), trend: trend(currentResult.totalDuration, previousResult.totalDuration))
            kpiCard(title: "Sorties", value: String(currentResult.activityCount), trend: trend(Double(currentResult.activityCount), Double(previousResult.activityCount)))
        }
    }

    private func kpiCard(title: String, value: String, trend: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.monospacedDigit().bold())
            if let trend, trend.isFinite {
                let pct = (trend * 100).rounded()
                Label("\(pct >= 0 ? "+" : "")\(Int(pct)) % vs \(selectedYear - 1)", systemImage: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(pct >= 0 ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private var breakdownChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ventilation par activité — \(selectedYear)").font(.headline)
            Chart {
                ForEach(breakdownEntries, id: \.type) { entry in
                    BarMark(
                        x: .value("Valeur", entry.value),
                        y: .value("Activité", entry.type.displayName)
                    )
                    .foregroundStyle(by: .value("Activité", entry.type.displayName))
                    .annotation(position: .trailing) {
                        Text(entry.formatted).font(.caption.monospacedDigit())
                    }
                }
            }
            .frame(height: max(120, CGFloat(breakdownEntries.count) * 32))
        }
    }

    private var breakdownEntries: [(type: ActivityType, value: Double, formatted: String)] {
        currentResult.byActivityType.map { (type, breakdown) -> (ActivityType, Double, String) in
            let val: Double
            let formatted: String
            switch selectedMetric {
            case .distance:
                val = breakdown.totalDistance
                formatted = Self.formatDistance(val)
            case .elevationGain:
                val = breakdown.totalElevationGain
                formatted = "\(Int(val.rounded())) m"
            case .duration:
                val = breakdown.totalDuration
                formatted = Self.formatDuration(val)
            case .count:
                val = Double(breakdown.activityCount)
                formatted = "\(Int(val))"
            }
            return (type, val, formatted)
        }
        .sorted { $0.1 > $1.1 }
    }

    private var cumulativeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(selectedYear) vs \(selectedYear - 1)").font(.headline)
            Chart {
                ForEach(YearComparisonBuilder.cumulative(activities: filteredActivities, year: selectedYear, metric: selectedMetric)) { p in
                    LineMark(
                        x: .value("Jour", p.dayOfYear),
                        y: .value(selectedMetric.rawValue, p.cumulativeValue),
                        series: .value("Année", "\(selectedYear)")
                    )
                    .foregroundStyle(.tint)
                }
                ForEach(YearComparisonBuilder.cumulative(activities: filteredActivities, year: selectedYear - 1, metric: selectedMetric)) { p in
                    LineMark(
                        x: .value("Jour", p.dayOfYear),
                        y: .value(selectedMetric.rawValue, p.cumulativeValue),
                        series: .value("Année", "\(selectedYear - 1)")
                    )
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
            }
            .chartXAxis {
                AxisMarks(values: [1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335]) { value in
                    AxisValueLabel(Self.monthLabel(forDayOfYear: value.as(Int.self) ?? 1))
                }
            }
            .frame(height: 220)
        }
    }

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tableau croisé — \(selectedYear)").font(.headline)
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("Activité").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        ForEach(1...12, id: \.self) { month in
                            Text(Self.shortMonth(month)).foregroundStyle(.secondary).frame(width: 48)
                        }
                    }
                    Divider().gridCellColumns(13)
                    ForEach(ActivityType.allCases.filter { hasActivityInYear($0) }, id: \.self) { type in
                        GridRow {
                            Text(type.displayName).gridColumnAlignment(.leading)
                            ForEach(1...12, id: \.self) { month in
                                let value = monthValue(type: type, month: month)
                                Text(value.isEmpty ? "—" : value)
                                    .frame(width: 48)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredActivities: [ActivitySummary] {
        if selectedTypes.isEmpty { return activities }
        return activities.filter { selectedTypes.contains($0.activityType) }
    }

    private func hasActivityInYear(_ type: ActivityType) -> Bool {
        currentResult.byActivityType[type] != nil
    }

    private func monthValue(type: ActivityType, month: Int) -> String {
        guard let bd = currentResult.byMonth?[month] else { return "" }
        let v = bd.byActivityType[type] ?? 0
        guard v > 0 else { return "" }
        switch selectedMetric {
        case .distance:      return String(format: "%.0f", v / 1000) + " km"
        case .elevationGain: return "\(Int(v.rounded()))"
        case .duration:      return Self.formatDuration(v)
        case .count:         return "\(Int(v))"
        }
    }

    private func trend(_ current: Double, _ previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
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
