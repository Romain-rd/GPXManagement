import SwiftUI
import AppKit
import GPXCore

struct SidebarView: View {
    @Bindable var navigation: AppNavigationModel
    @Bindable var listVM: ActivityListViewModel

    @State private var renamingRaid: Raid?
    @State private var renameText = ""
    @AppStorage("sidebarTypesExpanded") private var typesExpanded = false

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
            Label("Toutes les activités", systemImage: "tray.full")
        }
        .badge(listVM.allActivities.count)
        .tag(SidebarDestination.allActivities)
    }

    var body: some View {
        List(selection: selectionBinding) {
            allActivitiesRow

            if typesExpanded {
                ForEach(listVM.availableActivityTypes, id: \.type) { entry in
                    Label(entry.type.displayName, systemImage: entry.type.symbolName)
                        .badge(entry.count)
                        .padding(.leading, 18)
                        .tag(SidebarDestination.activityType(entry.type))
                }
            }

            if !listVM.availableRaids.isEmpty {
                Section("Raids") {
                    ForEach(listVM.availableRaids, id: \.raid.id) { entry in
                        raidRow(entry.raid, count: entry.count)
                            .tag(SidebarDestination.raid(entry.raid.id))
                            .contextMenu {
                                Button("Renommer…") {
                                    renameText = entry.raid.name
                                    renamingRaid = entry.raid
                                }
                                Button("Supprimer le raid", role: .destructive) {
                                    Task { await listVM.deleteRaid(entry.raid.id) }
                                    if navigation.selectedRaidId == entry.raid.id { navigation.sidebarSelection = .allActivities }
                                }
                            }
                    }
                }
            }

            Section("Filtres intelligents") {
                ForEach(listVM.smartFilters) { filter in
                    Label(filter.name, systemImage: "folder.badge.gearshape")
                        .badge(listVM.count(for: filter))
                        .tag(SidebarDestination.smartFilter(filter.id))
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
            }
        }
        .navigationTitle("Bibliothèque")
        .listStyle(.sidebar)
        .alert("Renommer le raid", isPresented: Binding(get: { renamingRaid != nil }, set: { if !$0 { renamingRaid = nil } })) {
            TextField("Nom du raid", text: $renameText)
            Button("Annuler", role: .cancel) { renamingRaid = nil }
            Button("Renommer") {
                if let raid = renamingRaid {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { Task { await listVM.renameRaid(raid.id, name: name) } }
                }
                renamingRaid = nil
            }
        }
    }

    @ViewBuilder
    private func raidRow(_ raid: Raid, count: Int) -> some View {
        Label {
            Text(raid.name)
        } icon: {
            if let data = raid.coverImageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "flag.2.crossed")
            }
        }
        .badge(count)
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

extension ActivityType {
    var symbolName: String {
        switch self {
        case .cyclingRoad, .cyclingGravel, .virtualRide, .velomobile: return "bicycle"
        case .cyclingMTB:                  return "bicycle.circle"
        case .eBike, .eMountainBike:       return "bicycle.circle.fill"
        case .handcycle:                   return "figure.roll"
        case .motorcycle:                  return "motorcycle"
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
