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
        case .cyclingRoad, .cyclingGravel, .virtualRide, .velomobile: return "bicycle"
        case .cyclingMTB:                  return "bicycle.circle"
        case .eBike, .eMountainBike:       return "bicycle.circle.fill"
        case .handcycle:                   return "figure.roll"
        case .motorcycle:                  return "fuelpump"
        case .walking:                     return "figure.walk"
        case .hiking:                      return "figure.hiking"
        case .running, .virtualRun:        return "figure.run"
        case .trailRunning:                return "figure.run.square.stack"
        case .mountaineering:              return "mountain.2.fill"
        case .skiingAlpine:                return "figure.skiing.downhill"
        case .skiingNordic:                return "figure.skiing.crosscountry"
        case .skiingTouring:               return "mountain.2"
        case .skiingFreeride:              return "snowflake"
        case .rollerSki:                   return "figure.skiing.crosscountry"
        case .snowboard:                   return "figure.snowboarding"
        case .snowshoe:                    return "snow"
        case .iceSkate:                    return "figure.ice.skating"
        case .inlineSkate:                 return "figure.roll"
        case .skateboard:                  return "skateboard"
        case .swimming:                    return "figure.pool.swim"
        case .rowing, .virtualRow:         return "figure.rower"
        case .canoeing, .kayaking:         return "figure.outdoor.rowing"
        case .standUpPaddling:             return "figure.surfing"
        case .surfing:                     return "figure.surfing"
        case .kitesurf, .windsurf:         return "wind"
        case .sailing:                     return "sailboat"
        case .climbing:                    return "figure.climbing"
        case .strengthTraining:            return "dumbbell"
        case .crossfit, .hiit:             return "figure.highintensity.intervaltraining"
        case .elliptical:                  return "figure.elliptical"
        case .stairStepper:                return "figure.stairs"
        case .pilates:                     return "figure.pilates"
        case .yoga:                        return "figure.yoga"
        case .workout:                     return "figure.mixed.cardio"
        case .golf:                        return "figure.golf"
        case .wheelchair:                  return "figure.roll"
        case .badminton:                   return "figure.badminton"
        case .tennis:                      return "figure.tennis"
        case .tableTennis:                 return "figure.table.tennis"
        case .pickleball:                  return "figure.pickleball"
        case .racquetball:                 return "figure.racquetball"
        case .squash:                      return "figure.squash"
        case .soccer:                      return "figure.soccer"
        case .other:                       return "questionmark.circle"
        }
    }
}
