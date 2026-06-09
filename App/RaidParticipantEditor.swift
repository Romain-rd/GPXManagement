import SwiftUI
import PhotosUI
import GPXCore
import GPXVideo

struct RaidLayoutThumbnail: View {
    let layout: VideoLayout
    let aspect: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.18))
                zone(layout.trace, in: geo.size, color: .blue)
                if let profile = layout.profile {
                    zone(profile, in: geo.size, color: .teal)
                }
                zone(layout.media, in: geo.size, color: .orange)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func zone(_ z: LayoutZone, in size: CGSize, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: 1.2))
            .frame(width: max(1, z.w * size.width), height: max(1, z.h * size.height))
            .offset(x: z.x * size.width, y: z.y * size.height)
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
