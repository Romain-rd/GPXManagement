import SwiftUI
import GPXCore

extension ImportProposal {
    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .long; f.timeStyle = .none
        return f
    }()

    /// Titre par défaut : le vrai nom du fichier (rare en FIT), sinon « Type — date » (ex. « Escalade — 15 avril 2026 »).
    func defaultTitle(for type: ActivityType) -> String {
        if let name = parsed.name, !name.isEmpty { return name }
        let date = parsed.startDate ?? parsed.summary?.startDate ?? Date()
        return "\(type.displayName) — \(Self.titleDateFormatter.string(from: date))"
    }
}

struct ImportSheetView: View {
    @Bindable var services: AppServices
    @State private var editedTitle: String = ""
    @State private var editedType: ActivityType = .cyclingRoad
    @State private var isNaming = false

    private var currentProposal: ImportProposal? {
        services.pendingImports.first
    }

    var body: some View {
        Group {
            if let proposal = currentProposal {
                proposalForm(for: proposal)
            } else {
                ContentUnavailableView("Aucun fichier en attente", systemImage: "tray")
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { prefill() }
        .onChange(of: currentProposal?.sourceURL) { _, _ in prefill() }
    }

    @ViewBuilder
    private func proposalForm(for proposal: ImportProposal) -> some View {
        VStack(spacing: 0) {
            header(for: proposal)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleAndTypeSection(proposal: proposal)
                    metricsGrid(proposal: proposal)
                    if proposal.duplicateOfActivityId != nil {
                        duplicateBanner
                    }
                }
                .padding(20)
            }
            Divider()
            footer(for: proposal)
        }
    }

    private func header(for proposal: ImportProposal) -> some View {
        let detected = proposal.suggestedActivityType ?? editedType
        return HStack(spacing: 12) {
            Image(systemName: detected.symbolName)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Importer une activité")
                    .font(.headline)
                Text(proposal.sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if services.pendingImports.count > 1 {
                Text("\(services.pendingImports.count) en attente")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func titleAndTypeSection(proposal: ImportProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Titre de l'activité", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
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
            HStack(spacing: 8) {
                Text("Type")
                    .foregroundStyle(.secondary)
                Picker("", selection: $editedType) {
                    ForEach(ActivityType.allCases, id: \.self) { type in
                        Label(type.displayName, systemImage: type.symbolName).tag(type)
                    }
                }
                .labelsHidden()
                if let suggested = proposal.suggestedActivityType, suggested != editedType {
                    Button {
                        editedType = suggested
                    } label: {
                        Label("Détecté : \(suggested.displayName)", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Utiliser le type détecté automatiquement")
                }
                Spacer()
            }
        }
    }

    private func metricsGrid(proposal: ImportProposal) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricCard(icon: "calendar", value: Self.formatDate(proposal.parsed.startDate), label: "Date", tint: .blue)
            MetricCard(icon: "ruler", value: Self.formatDistance(proposal.stats.distance), label: "Distance", tint: .blue)
            MetricCard(icon: "arrow.up.forward", value: "\(Int(proposal.stats.elevationGain.rounded())) m", label: "Dénivelé +", tint: .green)
            MetricCard(icon: "clock", value: Self.formatDuration(proposal.stats.duration), label: "Durée", tint: .purple)
        }
    }

    private var duplicateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Doublon probable")
                    .font(.callout.weight(.semibold))
                Text("Une activité similaire est déjà présente dans votre bibliothèque.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func footer(for proposal: ImportProposal) -> some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                services.cancelImport(proposal)
            } label: {
                Text("Ignorer")
            }
            Button("Tout annuler") {
                services.cancelAllImports()
            }
            Spacer()
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background.secondary)
    }

    private func prefill() {
        if let p = currentProposal {
            editedType = p.suggestedActivityType ?? .cyclingRoad
            editedTitle = p.defaultTitle(for: editedType)
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

