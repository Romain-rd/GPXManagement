import SwiftUI
import GPXCore

enum DetailTab: String, CaseIterable, Identifiable {
    case map = "Carte"
    case profile = "Profil"
    case stats = "Statistiques"
    case notes = "Notes"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .map:     return "map"
        case .profile: return "chart.xyaxis.line"
        case .stats:   return "list.bullet.rectangle"
        case .notes:   return "note.text"
        }
    }
}

struct ActivityDetailView: View {
    let activity: ActivitySummary
    @Bindable var listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    @State private var selectedTab: DetailTab = .stats
    @State private var notesDraft: String = ""
    @State private var shareURL: URL?
    @State private var isShareSheetPresented = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Vue", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Group {
                switch selectedTab {
                case .map:     ActivityMapTabView(activity: activity, repository: repository)
                case .profile: ElevationProfileTabView(activityId: activity.id, repository: repository)
                case .stats:   StatsTabView(activity: activity)
                case .notes:   NotesTabView(activity: activity, listVM: listVM, draft: $notesDraft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical)
        .navigationTitle(activity.title)
        .onAppear { notesDraft = activity.notes ?? "" }
        .onChange(of: activity.id) { _, _ in
            notesDraft = activity.notes ?? ""
            selectedTab = .stats
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await listVM.autoRename(id: activity.id) }
                } label: {
                    if listVM.renamingIds.contains(activity.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Nommer d'après le parcours", systemImage: "mappin.and.ellipse")
                    }
                }
                .disabled(listVM.renamingIds.contains(activity.id))
                .help("Renomme l'activité avec lieu de départ → point de passage → arrivée")

                Button {
                    Task { await exportGPX() }
                } label: {
                    Label("Exporter en GPX", systemImage: "arrow.down.doc")
                }
                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("Partager", systemImage: "square.and.arrow.up")
                }
            }
        }
        .background(
            ShareSheetPresenter(isPresented: $isShareSheetPresented, url: shareURL)
        )
        .alert("Export", isPresented: hasExportErrorBinding) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var hasExportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private func exportGPX() async {
        do {
            _ = try await ExportService.exportGPX(activity: activity, repository: repository)
        } catch ExportError.userCancelled {
            // silent
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func prepareShare() async {
        do {
            shareURL = try await ExportService.prepareShareGPX(activity: activity, repository: repository)
            isShareSheetPresented = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.title2.bold())
                Text("\(activity.activityType.displayName) · \(Self.formatDate(activity.startDate))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: d)
    }
}

struct MapPlaceholderView: View {
    var body: some View {
        contentUnavailable(
            title: "Carte",
            message: "Sera disponible en P6 (MapKit + tuiles IGN).",
            systemImage: "map"
        )
    }
}

struct ProfilePlaceholderView: View {
    var body: some View {
        contentUnavailable(
            title: "Profil altimétrique",
            message: "Sera disponible en P7 (Swift Charts).",
            systemImage: "chart.xyaxis.line"
        )
    }
}

@ViewBuilder
private func contentUnavailable(title: String, message: String, systemImage: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: systemImage)
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
        Text(title).font(.title3)
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

struct StatsTabView: View {
    let activity: ActivitySummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    statRow("Distance", Self.formatDistance(activity.distance))
                    statRow("Dénivelé +", "\(Int(activity.elevationGain.rounded())) m")
                    statRow("Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m")
                    statRow("Durée totale", Self.formatDuration(activity.duration))
                    statRow("Durée en mouvement", Self.formatDuration(activity.movingDuration))
                    statRow("Vitesse moyenne", Self.formatSpeed(activity.avgSpeed))
                    statRow("Vitesse max", Self.formatSpeed(activity.maxSpeed))
                    if let hr = activity.avgHeartRate {
                        statRow("FC moyenne", "\(Int(hr.rounded())) bpm")
                    }
                    if let hr = activity.maxHeartRate {
                        statRow("FC max", "\(Int(hr.rounded())) bpm")
                    }
                    statRow("Fichier source", "\(activity.sourceFileFormat.rawValue.uppercased()) · \(activity.sourceFileName)")
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).bold()
        }
    }

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.2f km", m / 1000) }
        return "\(Int(m)) m"
    }

    private static func formatDuration(_ s: Double) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, sec)
    }

    private static func formatSpeed(_ mps: Double) -> String {
        String(format: "%.1f km/h", mps * 3.6)
    }
}

struct NotesTabView: View {
    let activity: ActivitySummary
    @Bindable var listVM: ActivityListViewModel
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
                .padding(.horizontal)
            TextEditor(text: $draft)
                .border(.secondary.opacity(0.3))
                .padding(.horizontal)
            HStack {
                Spacer()
                Button("Enregistrer") {
                    Task { await listVM.updateNotes(id: activity.id, notes: draft) }
                }
                .disabled(draft == (activity.notes ?? ""))
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
    }
}
