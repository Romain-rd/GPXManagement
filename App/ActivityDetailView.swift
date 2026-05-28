import SwiftUI
import GPXCore

struct ActivityDetailView: View {
    let activity: ActivitySummary
    @Bindable var listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    @State private var notesDraft: String = ""
    @State private var shareURL: URL?
    @State private var isShareSheetPresented = false
    @State private var exportError: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                metricsGrid
                profileSection
                notesSection
            }
            .padding(20)
        }
        .navigationTitle(activity.title)
        .onAppear { notesDraft = activity.notes ?? "" }
        .onChange(of: activity.id) { _, _ in notesDraft = activity.notes ?? "" }
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
        .background(ShareSheetPresenter(isPresented: $isShareSheetPresented, url: shareURL))
        .alert("Export", isPresented: hasExportErrorBinding) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Button {
                        Task { await listVM.updateType(id: activity.id, type: type) }
                    } label: {
                        Label(type.displayName, systemImage: type == activity.activityType ? "checkmark" : type.symbolName)
                    }
                }
            } label: {
                Image(systemName: activity.activityType.symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.tint.opacity(0.15)))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary, Color(NSColor.windowBackgroundColor))
                    }
            }
            .buttonStyle(.plain)
            .help("Changer le type d'activité")
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title).font(.title.bold())
                Text("\(activity.activityType.displayName) · \(Self.formatDate(activity.startDate))")
                    .foregroundStyle(.secondary)
                if !activity.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(activity.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            MetricCard(icon: "ruler", value: Self.distance(activity.distance), label: "Distance", tint: .blue)
            MetricCard(icon: "arrow.up.forward", value: "\(Int(activity.elevationGain.rounded())) m", label: "Dénivelé +", tint: .green)
            MetricCard(icon: "arrow.down.forward", value: "\(Int(activity.elevationLoss.rounded())) m", label: "Dénivelé −", tint: .orange)
            MetricCard(icon: "clock", value: Self.duration(activity.duration), label: "Durée totale", tint: .purple)
            MetricCard(icon: "stopwatch", value: Self.duration(activity.movingDuration), label: "En mouvement", tint: .purple)
            MetricCard(icon: "speedometer", value: Self.speed(activity.avgSpeed), label: "Vitesse moy.", tint: .teal)
            MetricCard(icon: "gauge.with.dots.needle.67percent", value: Self.speed(activity.maxSpeed), label: "Vitesse max", tint: .teal)
            if let hr = activity.avgHeartRate {
                MetricCard(icon: "heart", value: "\(Int(hr.rounded())) bpm", label: "FC moyenne", tint: .red)
            }
            if let hr = activity.maxHeartRate {
                MetricCard(icon: "heart.fill", value: "\(Int(hr.rounded())) bpm", label: "FC max", tint: .red)
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Profil altimétrique", systemImage: "chart.xyaxis.line")
                .font(.headline)
            ElevationProfileTabView(activityId: activity.id, repository: repository)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Notes", systemImage: "note.text").font(.headline)
                Spacer()
                Button("Enregistrer") {
                    Task { await listVM.updateNotes(id: activity.id, notes: notesDraft) }
                }
                .disabled(notesDraft == (activity.notes ?? ""))
            }
            TextEditor(text: $notesDraft)
                .frame(minHeight: 100)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            Text("Fichier source : \(activity.sourceFileFormat.rawValue.uppercased()) · \(activity.sourceFileName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var hasExportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private func exportGPX() async {
        do {
            _ = try await ExportService.exportGPX(activity: activity, repository: repository)
        } catch ExportError.userCancelled {
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

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: d)
    }

    private static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m"
    }

    private static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, sec)
    }

    private static func speed(_ mps: Double) -> String {
        String(format: "%.1f km/h", mps * 3.6)
    }
}

struct MetricCard: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}
