import SwiftUI
import AppKit
import PhotosUI
import GPXCore
import GPXMapKit

struct RaidDetailView: View {
    let raid: Raid
    let listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    let navigation: AppNavigationModel

    @State private var draft: Raid
    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignScan25.rawValue
    @State private var layer: MapLayer = .ignScan25
    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoadingMap = true
    @State private var proxy = MapViewProxy()
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var editingParticipant: RaidParticipant?
    @State private var isAddingParticipant = false

    init(raid: Raid, listVM: ActivityListViewModel, repository: CoreDataActivityRepository, navigation: AppNavigationModel) {
        self.raid = raid
        self.listVM = listVM
        self.repository = repository
        self.navigation = navigation
        _draft = State(initialValue: raid)
    }

    private var members: [ActivitySummary] {
        listVM.allActivities.filter { $0.raidId == raid.id }.sorted { $0.startDate < $1.startDate }
    }

    private var isDirty: Bool {
        draft.name != raid.name
            || (draft.place ?? "") != (raid.place ?? "")
            || (draft.notes ?? "") != (raid.notes ?? "")
            || draft.participants != raid.participants
            || draft.coverImageData != raid.coverImageData
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                coverBanner
                header
                statsGrid
                participantsSection
                mapCard
                stepsSection
                infoSection
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(raid.name)
        .task(id: raid.id) { await loadMap() }
        .onAppear { layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25 }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
        .onChange(of: coverPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let resized = Self.downscaledJPEG(data, maxDimension: 1600) {
                    draft.coverImageData = resized
                    await listVM.saveRaid(draft)
                }
                coverPickerItem = nil
            }
        }
        .sheet(isPresented: $isAddingParticipant) {
            RaidParticipantEditor(participant: RaidParticipant(name: ""), onSave: { updated in
                draft.participants.append(updated)
                persist()
            }, onDelete: nil)
        }
        .sheet(item: $editingParticipant) { participant in
            RaidParticipantEditor(participant: participant, onSave: { updated in
                if let idx = draft.participants.firstIndex(where: { $0.id == updated.id }) {
                    draft.participants[idx] = updated
                    persist()
                }
            }, onDelete: {
                draft.participants.removeAll { $0.id == participant.id }
                persist()
            })
        }
    }

    // MARK: Couverture

    @ViewBuilder
    private var coverBanner: some View {
        if let data = draft.coverImageData, let image = NSImage(data: data) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Menu {
                    PhotosPicker("Changer la photo…", selection: $coverPickerItem, matching: .images)
                    Button("Retirer la photo", role: .destructive) {
                        draft.coverImageData = nil
                        persist()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(10)
            }
        } else {
            PhotosPicker(selection: $coverPickerItem, matching: .images) {
                Label("Ajouter une photo de couverture", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Participants").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(draft.participants) { participant in
                    Button { editingParticipant = participant } label: {
                        participantChip(participant)
                    }
                    .buttonStyle(.plain)
                }
                Button { isAddingParticipant = true } label: {
                    Label("Ajouter", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func participantChip(_ participant: RaidParticipant) -> some View {
        HStack(spacing: 8) {
            ParticipantAvatar(participant: participant, size: 28)
            Text(participant.name.isEmpty ? "Sans nom" : participant.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: Capsule())
        .contentShape(Capsule())
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "flag.2.crossed.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                TextField("Nom du raid", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .onSubmit { save() }
            }
            TextField("Lieu / région (facultatif)", text: Binding(
                get: { draft.place ?? "" },
                set: { draft.place = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .font(.title3)
            .foregroundStyle(.secondary)
            .onSubmit { save() }

            if let range = dateRangeText {
                Label(range, systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Statistiques cumulées

    private var statsGrid: some View {
        let totalDistance = members.reduce(0) { $0 + $1.distance }
        let totalGain = members.reduce(0) { $0 + $1.elevationGain }
        let totalMoving = members.reduce(0) { $0 + $1.movingDuration }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
            statTile("Étapes", "\(members.count)", "point.topleft.down.to.point.bottomright.curvepath")
            statTile("Distance", Self.formatDistance(totalDistance), "ruler")
            statTile("Dénivelé +", "\(Int(totalGain.rounded())) m", "mountain.2")
            statTile("Temps en mouvement", Self.formatDuration(totalMoving), "stopwatch")
        }
    }

    private func statTile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title3.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Carte multi-traces

    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isLoadingMap {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                } else if tracks.isEmpty {
                    ContentUnavailableView("Aucune trace", systemImage: "map",
                                           description: Text("Les étapes de ce raid n'ont pas de données GPS."))
                        .frame(minHeight: 320)
                } else {
                    TrackMapView(tracks: tracks, layer: $layer, proxy: proxy, onSelectActivity: { id in
                        navigation.listSelection = [id]
                    })
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            if !tracks.isEmpty {
                LayerPicker(layer: $layer).padding(8)
            }
        }
    }

    // MARK: Étapes

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Étapes").font(.headline)
            if members.isEmpty {
                Text("Aucune activité dans ce raid.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, activity in
                    Button {
                        navigation.listSelection = [activity.id]
                    } label: {
                        stepRow(index: index + 1, activity: activity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stepRow(index: Int, activity: ActivitySummary) -> some View {
        HStack(spacing: 12) {
            Text("J\(index)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.15), in: Circle())
            Image(systemName: activity.activityType.symbolName)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.body)
                Text(Self.dayFormatter.string(from: activity.startDate))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.formatDistance(activity.distance)).font(.callout.monospacedDigit())
                Text("\(Int(activity.elevationGain.rounded())) m D+")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Informations / notes

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                if isDirty {
                    Button("Enregistrer") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            TextEditor(text: Binding(
                get: { draft.notes ?? "" },
                set: { draft.notes = $0.isEmpty ? nil : $0 }
            ))
            .frame(minHeight: 90)
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .font(.body)
        }
    }

    // MARK: Actions

    private func save() {
        guard isDirty else { return }
        persist()
    }

    private func persist() {
        let snapshot = draft
        Task { await listVM.saveRaid(snapshot) }
    }

    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat = 0.8) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func loadMap() async {
        isLoadingMap = true
        var loaded: [TrackOverlayInput] = []
        for activity in members {
            if let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
               let overlay = try? TrackOverlayInput.fromTrackData(data, activityId: activity.id, activityType: activity.activityType),
               !overlay.coordinates.isEmpty {
                loaded.append(overlay)
            }
        }
        tracks = loaded
        isLoadingMap = false
    }

    // MARK: Formatage

    private var dateRangeText: String? {
        guard let start = raid.startDate else { return nil }
        let end = raid.endDate ?? start
        let cal = Calendar.current
        if cal.isDate(start, inSameDayAs: end) {
            return Self.dayFormatter.string(from: start)
        }
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0) + 1
        return "\(Self.dayFormatter.string(from: start)) → \(Self.dayFormatter.string(from: end)) · \(days) jours"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m))" }
        return "\(m) min"
    }
}

struct ParticipantAvatar: View {
    let participant: RaidParticipant
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let data = participant.avatarImageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.accentColor.opacity(0.25)
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = participant.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

struct RaidParticipantEditor: View {
    @State private var participant: RaidParticipant
    let onSave: (RaidParticipant) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var avatarItem: PhotosPickerItem?

    init(participant: RaidParticipant, onSave: @escaping (RaidParticipant) -> Void, onDelete: (() -> Void)?) {
        _participant = State(initialValue: participant)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onDelete == nil ? "Nouveau participant" : "Modifier le participant")
                .font(.headline)

            HStack(spacing: 16) {
                ParticipantAvatar(participant: participant, size: 72)
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(participant.avatarImageData == nil ? "Choisir une photo…" : "Changer la photo…",
                                 selection: $avatarItem, matching: .images)
                    if participant.avatarImageData != nil {
                        Button("Retirer la photo", role: .destructive) { participant.avatarImageData = nil }
                            .buttonStyle(.link)
                    }
                }
            }

            TextField("Nom", text: $participant.name)
                .textFieldStyle(.roundedBorder)

            HStack {
                if onDelete != nil {
                    Button("Supprimer", role: .destructive) {
                        onDelete?()
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") {
                    onSave(participant)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(participant.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let resized = RaidDetailView.downscaledJPEG(data, maxDimension: 256) {
                    participant.avatarImageData = resized
                }
                avatarItem = nil
            }
        }
    }
}
