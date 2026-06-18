import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct SidebarView: View {
    @Bindable var navigation: AppNavigationModel
    @Bindable var listVM: ActivityListViewModel

    @AppStorage("sidebarTypesExpanded") private var typesExpanded = false
    @AppStorage("sidebarYearsExpanded") private var yearsExpanded = true
    @AppStorage("sidebarRaidsExpanded") private var raidsExpanded = true
    @AppStorage("sidebarParcoursExpanded") private var parcoursExpanded = true
    @AppStorage("sidebarSmartExpanded") private var smartExpanded = true
    @State private var expandedYears: Set<Int> = []

    private var selectionBinding: Binding<SidebarDestination?> {
        Binding(get: { navigation.sidebarSelection }, set: { navigation.sidebarSelection = $0 ?? .allActivities })
    }

    private var allActivitiesRow: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { typesExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(typesExpanded ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(listVM.availableActivityTypes.isEmpty ? 0 : 1)
            .disabled(listVM.availableActivityTypes.isEmpty)
            Label {
                Text("Activités")
            } icon: {
                Image(systemName: "tray.full").foregroundStyle(.tint)
            }
        }
        .badge(listVM.activitiesCount)
        .tag(SidebarDestination.allActivities)
    }

    private var allCoursesRow: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { parcoursExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(parcoursExpanded ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(listVM.courseActivityTypes.isEmpty ? 0 : 1)
            .disabled(listVM.courseActivityTypes.isEmpty)
            Label {
                Text("Parcours")
            } icon: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.tint)
            }
        }
        .badge(listVM.coursesCount)
        .tag(SidebarDestination.allCourses)
    }

    var body: some View {
        List(selection: selectionBinding) {
            allActivitiesRow

            if typesExpanded {
                ForEach(listVM.availableActivityTypes, id: \.type) { entry in
                    Label {
                        Text(entry.type.displayName)
                    } icon: {
                        Image(systemName: entry.type.symbolName)
                            .foregroundStyle(Color(nsColor: entry.type.trackColor))
                    }
                    .badge(entry.count)
                    .padding(.leading, 18)
                    .tag(SidebarDestination.activityType(entry.type))
                    .id(SidebarDestination.activityType(entry.type))
                }
            }

            if !listVM.courseActivities.isEmpty {
                allCoursesRow
                if parcoursExpanded {
                    ForEach(listVM.courseActivityTypes, id: \.type) { entry in
                        Label {
                            Text(entry.type.displayName)
                        } icon: {
                            Image(systemName: entry.type.symbolName)
                                .foregroundStyle(Color(nsColor: entry.type.trackColor))
                        }
                        .badge(entry.count)
                        .padding(.leading, 18)
                        .tag(SidebarDestination.courseType(entry.type))
                        .id(SidebarDestination.courseType(entry.type))
                    }
                }
            }

            if !listVM.availableRaids.isEmpty {
                HStack(spacing: 2) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { raidsExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(raidsExpanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(listVM.raidActivityTypes.isEmpty ? 0 : 1)
                    .disabled(listVM.raidActivityTypes.isEmpty)
                    Label {
                        Text("Raids")
                    } icon: {
                        Image(systemName: "flag.2.crossed").foregroundStyle(.orange)
                    }
                }
                .badge(listVM.availableRaids.count)
                .tag(SidebarDestination.allRaids)

                if raidsExpanded {
                    ForEach(listVM.raidActivityTypes, id: \.type) { entry in
                        Label {
                            Text(entry.type.displayName)
                        } icon: {
                            Image(systemName: entry.type.symbolName)
                                .foregroundStyle(Color(nsColor: entry.type.trackColor))
                        }
                        .badge(entry.count)
                        .padding(.leading, 18)
                        .tag(SidebarDestination.raidType(entry.type))
                        .id(SidebarDestination.raidType(entry.type))
                    }
                }
            }

            if !listVM.availableYears.isEmpty {
                Section(isExpanded: $yearsExpanded) {
                    ForEach(listVM.availableYears, id: \.year) { entry in
                        yearRow(entry.year, count: entry.count)
                        if expandedYears.contains(entry.year) {
                            ForEach(listVM.availableActivityTypes(year: entry.year), id: \.type) { sub in
                                Label {
                                    Text(sub.type.displayName)
                                } icon: {
                                    Image(systemName: sub.type.symbolName)
                                        .foregroundStyle(Color(nsColor: sub.type.trackColor))
                                }
                                .badge(sub.count)
                                .padding(.leading, 18)
                                .tag(SidebarDestination.yearType(entry.year, sub.type))
                                .id(SidebarDestination.yearType(entry.year, sub.type))
                            }
                        }
                    }
                } header: {
                    Text("Années")
                }
            }

            Section(isExpanded: $smartExpanded) {
                ForEach(listVM.smartFilters) { filter in
                    Label {
                        Text(filter.name)
                    } icon: {
                        Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
                    }
                        .badge(listVM.count(for: filter))
                        .tag(SidebarDestination.smartFilter(filter.id))
                        .contentShape(Rectangle())
                        // Double-clic → éditeur (façon boîtes intelligentes de Mail). Le geste double-clic
                        // avale le clic simple selon les versions de macOS : on pose donc la sélection
                        // explicitement au premier clic au lieu de compter sur la List.
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            navigation.sidebarSelection = .smartFilter(filter.id)
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            navigation.editingSmartFilter = filter
                        })
                        .contextMenu {
                            Button("Modifier…") { navigation.editingSmartFilter = filter }
                            Button("Supprimer", role: .destructive) {
                                Task { await listVM.deleteSmartFilter(filter.id) }
                                if navigation.selectedSmartFilterId == filter.id { navigation.sidebarSelection = .allActivities }
                            }
                        }
                }
                Button {
                    navigation.editingSmartFilter = SmartFilter(name: "Nouveau filtre", rules: [SmartFilterRule()])
                } label: {
                    Label("Nouveau filtre intelligent…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Filtres intelligents")
            }
        }
        .navigationTitle("Bibliothèque")
        .listStyle(.sidebar)
    }

    private func yearRow(_ year: Int, count: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expandedYears.contains(year) { expandedYears.remove(year) } else { expandedYears.insert(year) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expandedYears.contains(year) ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Label {
                Text(String(year))
            } icon: {
                Image(systemName: "calendar").foregroundStyle(.tint)
            }
        }
        .badge(count)
        .tag(SidebarDestination.year(year))
    }
}

struct FacetRow: View {
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

