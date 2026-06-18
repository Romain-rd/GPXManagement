import SwiftUI
import WebKit

/// Vue web (WKWebView) pour afficher un HTML local : SwiftUI n'a pas de WebView sur macOS 15 — même pont
/// `NSViewRepresentable` que MKMapView. Charge un fichier du container avec accès lecture à son dossier.
struct WebFileView: NSViewRepresentable {
    let fileURL: URL
    let accessDir: URL
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.loadFileURL(fileURL, allowingReadAccessTo: accessDir)
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        if v.url != fileURL { v.loadFileURL(fileURL, allowingReadAccessTo: accessDir) }
    }
}

/// Aperçu local de la page web d'un parcours (test phases 1-3, avant la vraie publication Bunny).
/// Bascule Mobile / Bureau pour vérifier le responsive (tab bar bas ↔ rail à gauche).
struct RouteWebPreviewSheet: View {
    let dir: URL
    @State private var wide = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $wide) {
                    Label("Mobile", systemImage: "iphone").tag(false)
                    Label("Bureau", systemImage: "desktopcomputer").tag(true)
                }
                .pickerStyle(.segmented).labelStyle(.titleAndIcon).fixedSize()
                Spacer()
                Text("Aperçu web local").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            WebFileView(fileURL: dir.appendingPathComponent("index.html"), accessDir: dir)
                .frame(width: wide ? 1080 : 390, height: 760)
        }
    }
}
