import SwiftUI
import GPXCore

struct SidebarView: View {
    @Bindable var navigation: AppNavigationModel
    @Bindable var listVM: ActivityListViewModel

    var body: some View {
        List {
            Section("Activités") {
                FacetRow(
                    label: "Toutes",
                    systemImage: "tray.full",
                    count: listVM.allActivities.count,
                    isOn: listVM.filters.isEmpty
                ) {
                    listVM.filters.reset()
                }
                ForEach(listVM.availableActivityTypes, id: \.type) { entry in
                    FacetRow(
                        label: entry.type.displayName,
                        systemImage: entry.type.symbolName,
                        count: entry.count,
                        isOn: listVM.filters.activityTypes.contains(entry.type)
                    ) {
                        listVM.filters.toggleType(entry.type)
                    }
                }
            }

            if !listVM.availableYears.isEmpty {
                Section("Années") {
                    ForEach(listVM.availableYears, id: \.year) { entry in
                        FacetRow(
                            label: String(entry.year),
                            systemImage: "calendar",
                            count: entry.count,
                            isOn: listVM.filters.years.contains(entry.year)
                        ) {
                            listVM.filters.toggleYear(entry.year)
                        }
                    }
                }
            }

            if !listVM.availableTags.isEmpty {
                Section("Tags") {
                    ForEach(listVM.availableTags, id: \.tag) { entry in
                        FacetRow(
                            label: entry.tag,
                            systemImage: "tag",
                            count: entry.count,
                            isOn: listVM.filters.tags.contains(entry.tag)
                        ) {
                            listVM.filters.toggleTag(entry.tag)
                        }
                    }
                }
            }
        }
        .navigationTitle("Filtres")
        .listStyle(.sidebar)
    }
}

private struct FacetRow: View {
    let label: String
    let systemImage: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(label)
                    .fontWeight(isOn ? .semibold : .regular)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ActivityType {
    var symbolName: String {
        switch self {
        case .cyclingRoad, .cyclingGravel: return "bicycle"
        case .cyclingMTB:                  return "bicycle.circle"
        case .motorcycle:                  return "fuelpump"
        case .walking:                     return "figure.walk"
        case .hiking:                      return "figure.hiking"
        case .skiingAlpine:                return "figure.skiing.downhill"
        case .skiingNordic:                return "figure.skiing.crosscountry"
        case .skiingTouring:               return "mountain.2"
        case .skiingFreeride:              return "snowflake"
        }
    }
}
