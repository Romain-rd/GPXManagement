import SwiftUI
import GPXCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var services: AppServices = .shared
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(24)

            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 48))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text("Glissez vos fichiers GPX / FIT ici")
                    .font(.title3)
                Text("Import par lots accepté")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            Task { await services.prepareImports(from: urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: hasPendingImportsBinding) {
            ImportSheetView(services: services)
        }
        .alert("Erreur", isPresented: hasErrorBinding) {
            Button("OK") { services.importError = nil }
        } message: {
            Text(services.importError ?? "")
        }
    }

    private var hasPendingImportsBinding: Binding<Bool> {
        Binding(
            get: { !services.pendingImports.isEmpty },
            set: { if !$0 { services.cancelAllImports() } }
        )
    }

    private var hasErrorBinding: Binding<Bool> {
        Binding(
            get: { services.importError != nil },
            set: { if !$0 { services.importError = nil } }
        )
    }
}
