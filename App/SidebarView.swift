import SwiftUI
import GPXCore

struct SidebarView: View {
    @Bindable var navigation: AppNavigationModel
    @Bindable var listVM: ActivityListViewModel

    var body: some View {
        List(selection: Binding(
            get: { navigation.sidebarSelection },
            set: { newValue in
                guard let newValue else { return }
                navigation.sidebarSelection = newValue
                navigation.applySidebar(newValue, to: &listVM.filters)
            }
        )) {
            Section("Activités") {
                NavigationLink(value: SidebarItem.allActivities) {
                    Label("Toutes", systemImage: "tray.full")
                        .badge(listVM.allActivities.count)
                }
                ForEach(listVM.availableActivityTypes, id: \.type) { entry in
                    NavigationLink(value: SidebarItem.activityType(entry.type)) {
                        Label(entry.type.displayName, systemImage: entry.type.symbolName)
                            .badge(entry.count)
                    }
                }
            }

            if !listVM.availableYears.isEmpty {
                Section("Années") {
                    ForEach(listVM.availableYears, id: \.year) { entry in
                        let label = String(entry.year)
                        NavigationLink(value: SidebarItem.year(entry.year)) {
                            Label(label, systemImage: "calendar")
                                .badge(entry.count)
                        }
                    }
                }
            }

            if !listVM.availableTags.isEmpty {
                Section("Tags") {
                    ForEach(listVM.availableTags, id: \.tag) { entry in
                        NavigationLink(value: SidebarItem.tag(entry.tag)) {
                            Label(entry.tag, systemImage: "tag")
                                .badge(entry.count)
                        }
                    }
                }
            }

        }
        .navigationTitle("Filtres")
        .listStyle(.sidebar)
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
