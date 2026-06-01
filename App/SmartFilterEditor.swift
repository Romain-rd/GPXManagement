import SwiftUI
import GPXCore

struct SmartFilterEditor: View {
    let listVM: ActivityListViewModel
    let onSave: (SmartFilter) -> Void
    let onCancel: () -> Void

    @State private var draft: SmartFilter

    init(filter: SmartFilter, listVM: ActivityListViewModel, onSave: @escaping (SmartFilter) -> Void, onCancel: @escaping () -> Void) {
        self.listVM = listVM
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filtre intelligent").font(.title3.bold())

            TextField("Nom du filtre", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Text("Correspond à")
                Picker("", selection: $draft.matchAll) {
                    Text("toutes").tag(true)
                    Text("au moins une").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("des règles suivantes :")
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach($draft.rules) { $rule in
                    ruleRow($rule)
                }
                if draft.rules.isEmpty {
                    Text("Aucune règle : le filtre inclut toutes les activités.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                draft.rules.append(SmartFilterRule())
            } label: {
                Label("Ajouter une règle", systemImage: "plus.circle")
            }
            .buttonStyle(.link)

            Divider()
            HStack {
                Text("\(matchingCount) activité(s) correspondante(s)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { onCancel() }
                Button("Enregistrer") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var matchingCount: Int {
        listVM.allActivities.filter { draft.matches($0) }.count
    }

    @ViewBuilder
    private func ruleRow(_ rule: Binding<SmartFilterRule>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { rule.wrappedValue.field },
                set: { newField in
                    rule.wrappedValue.field = newField
                    rule.wrappedValue.op = Self.operators(for: newField).first ?? .isEqual
                    rule.wrappedValue.stringValue = Self.defaultStringValue(for: newField, listVM: listVM)
                    rule.wrappedValue.number1 = 0
                    rule.wrappedValue.number2 = 0
                }
            )) {
                ForEach(SmartFilterField.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
            }
            .labelsHidden().frame(width: 150)

            Picker("", selection: rule.op) {
                ForEach(Self.operators(for: rule.wrappedValue.field), id: \.self) { Text(Self.label(for: $0)).tag($0) }
            }
            .labelsHidden().frame(width: 140)

            valueEditor(rule)

            Spacer(minLength: 0)
            Button {
                draft.rules.removeAll { $0.id == rule.wrappedValue.id }
            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func valueEditor(_ rule: Binding<SmartFilterRule>) -> some View {
        switch rule.wrappedValue.field {
        case .raid:
            EmptyView()
        case .activityType:
            Picker("", selection: rule.stringValue) {
                ForEach(ActivityType.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }.labelsHidden().frame(width: 160)
        case .source:
            Picker("", selection: rule.stringValue) {
                ForEach(listVM.availableSources, id: \.source.id) { Text($0.source.displayName).tag($0.source.id) }
            }.labelsHidden().frame(width: 160)
        case .tag:
            if listVM.availableTags.isEmpty {
                TextField("tag", text: rule.stringValue).textFieldStyle(.roundedBorder).frame(width: 160)
            } else {
                Picker("", selection: rule.stringValue) {
                    ForEach(listVM.availableTags, id: \.tag) { Text($0.tag).tag($0.tag) }
                }.labelsHidden().frame(width: 160)
            }
        case .text:
            TextField("texte", text: rule.stringValue).textFieldStyle(.roundedBorder).frame(width: 180)
        case .date, .distance, .elevationGain, .duration, .avgSpeed, .avgHeartRate:
            HStack(spacing: 4) {
                TextField("", value: rule.number1, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                if rule.wrappedValue.op == .between {
                    Text("et")
                    TextField("", value: rule.number2, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                Text(Self.unit(for: rule.wrappedValue.field)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Libellés & opérateurs applicables

    static func operators(for field: SmartFilterField) -> [SmartFilterOperator] {
        switch field {
        case .activityType, .source: return [.isEqual, .isNot]
        case .tag:                    return [.contains, .isEqual]
        case .text:                   return [.contains]
        case .raid:                   return [.isTrue, .isFalse]
        case .date:                   return [.after, .before, .isEqual, .between]
        default:                      return [.greater, .less, .between]
        }
    }

    static func defaultStringValue(for field: SmartFilterField, listVM: ActivityListViewModel) -> String {
        switch field {
        case .activityType: return ActivityType.allCases.first?.rawValue ?? ""
        case .source:       return listVM.availableSources.first?.source.id ?? ""
        case .tag:          return listVM.availableTags.first?.tag ?? ""
        default:            return ""
        }
    }

    static func label(for field: SmartFilterField) -> String {
        switch field {
        case .activityType:  return "Type"
        case .date:          return "Date (année)"
        case .distance:      return "Distance"
        case .elevationGain: return "Dénivelé +"
        case .duration:      return "Durée"
        case .avgSpeed:      return "Vitesse moy."
        case .avgHeartRate:  return "FC moy."
        case .source:        return "Source"
        case .tag:           return "Tag"
        case .raid:          return "Raid"
        case .text:          return "Titre / Notes"
        }
    }

    static func label(for op: SmartFilterOperator) -> String {
        switch op {
        case .isEqual: return "est"
        case .isNot:   return "n'est pas"
        case .contains: return "contient"
        case .greater: return "supérieur à"
        case .less:    return "inférieur à"
        case .between: return "entre"
        case .before:  return "avant"
        case .after:   return "après"
        case .isTrue:  return "appartient à un raid"
        case .isFalse: return "hors raid"
        }
    }

    static func unit(for field: SmartFilterField) -> String {
        switch field {
        case .distance:      return "km"
        case .elevationGain: return "m"
        case .duration:      return "min"
        case .avgSpeed:      return "km/h"
        case .avgHeartRate:  return "bpm"
        default:             return ""
        }
    }
}
