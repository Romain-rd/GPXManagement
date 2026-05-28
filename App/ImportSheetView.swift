import SwiftUI
import GPXCore

struct ImportSheetView: View {
    @Bindable var services: AppServices
    @State private var editedTitle: String = ""
    @State private var editedType: ActivityType = .cyclingRoad
    @State private var isNaming = false

    private var currentProposal: ImportProposal? {
        services.pendingImports.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let proposal = currentProposal {
                HStack {
                    Text("Import — \(proposal.sourceURL.lastPathComponent)")
                        .font(.headline)
                    Spacer()
                    Text("\(services.pendingImports.count) en attente")
                        .foregroundStyle(.secondary)
                }

                Form {
                    HStack {
                        TextField("Titre", text: $editedTitle)
                        Button {
                            Task { await suggestName(from: proposal) }
                        } label: {
                            if isNaming {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "mappin.and.ellipse")
                            }
                        }
                        .disabled(isNaming)
                        .help("Nommer d'après le parcours (départ → passage → arrivée)")
                    }
                    Picker("Type d'activité", selection: $editedType) {
                        ForEach(ActivityType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    LabeledContent("Date", value: Self.formatDate(proposal.parsed.startDate))
                    LabeledContent("Distance", value: Self.formatDistance(proposal.stats.distance))
                    LabeledContent("Dénivelé positif", value: "\(Int(proposal.stats.elevationGain.rounded())) m")
                    LabeledContent("Durée", value: Self.formatDuration(proposal.stats.duration))
                    if let suggested = proposal.suggestedActivityType {
                        LabeledContent("Détecté", value: suggested.displayName)
                    }
                    if proposal.duplicateOfActivityId != nil {
                        Label("Doublon probable", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Button("Ignorer ce fichier") {
                        services.cancelImport(proposal)
                    }
                    Spacer()
                    Button("Tout annuler") {
                        services.cancelAllImports()
                    }
                    if services.pendingImports.count > 1 {
                        Button("Tout importer (\(services.pendingImports.count))") {
                            Task {
                                await services.confirmAllPendingImports(defaultActivityType: editedType)
                            }
                        }
                    }
                    Button("Importer") {
                        Task {
                            await services.confirmImport(proposal, activityType: editedType, title: editedTitle)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Aucun fichier en attente.")
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { prefill() }
        .onChange(of: currentProposal?.sourceURL) { _, _ in prefill() }
    }

    private func prefill() {
        if let p = currentProposal {
            editedTitle = p.suggestedTitle
            editedType = p.suggestedActivityType ?? .cyclingRoad
        }
    }

    private func suggestName(from proposal: ImportProposal) async {
        isNaming = true
        defer { isNaming = false }
        if let name = await RouteNamer.suggestName(points: proposal.parsed.points) {
            editedTitle = name
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    private static func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return "\(Int(meters)) m"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }
}
