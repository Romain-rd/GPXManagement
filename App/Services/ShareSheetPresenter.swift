import SwiftUI
import AppKit

struct ShareSheetPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let url: URL?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, let url else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            isPresented = false
        }
    }
}
