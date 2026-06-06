import SwiftUI

@main
struct GPXManagementApp: App {
    @State private var services = AppServices.shared

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        registerUbiquityContainer()
    }

    var body: some Scene {
        WindowGroup {
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
            } else {
                ContentView(services: services)
                    .environment(\.managedObjectContext, services.persistence.container.viewContext)
                    .alphaRibbon()
            }
        }
        .commands {
            AppMenuCommands(services: services)
        }

        Settings {
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
            } else {
                PreferencesView()
                    .alphaRibbon()
            }
        }
    }

    private func registerUbiquityContainer() {
        Task.detached(priority: .utility) {
            let identifier = AppConfig.iCloudContainerIdentifier
            guard let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
                NSLog("GPXManagement: ubiquity container '\(identifier)' unavailable")
                return
            }
            NSLog("GPXManagement: ubiquity container resolved at \(url.path)")
            let documents = url.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let marker = documents.appendingPathComponent(".initialized")
            try? "GPXManagement initialized\n".write(to: marker, atomically: true, encoding: .utf8)
        }
    }
}

/// Triangle plein « Alpha » dessiné dans le coin haut-droit, AU NIVEAU DE LA FENÊTRE (au-dessus de la barre
/// d'outils et de tout le contenu). Le clic n'est capté que sur le triangle ; le reste laisse passer.
final class AlphaCornerView: NSView {
    private let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let s = bounds.width
        // Triangle couvrant le coin haut-droit (sommets : haut-gauche, haut-droit, bas-droit).
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: 0, y: s))
        tri.line(to: NSPoint(x: s, y: s))
        tri.line(to: NSPoint(x: s, y: 0))
        tri.close()
        NSColor.systemRed.setFill()
        tri.fill()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let text = "ALPHA  \(AppConfig.fullVersion)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .black),
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let tsize = astr.size()
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: s * 2 / 3, y: s * 2 / 3) // centre du triangle (centroïde) → texte plein sur le rouge
            ctx.rotate(by: -.pi / 4)                    // aligne le texte sur la diagonale « ╲ »
            astr.draw(at: NSPoint(x: -tsize.width / 2, y: -tsize.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // Ne capter le clic que dans le triangle ; ailleurs, laisser passer (boutons de la toolbar dessous).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let p = superview?.convert(point, to: self) else { return nil }
        let s = bounds.width
        return (bounds.contains(p) && p.x + p.y >= s) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        NSWorkspace.shared.open(AppConfig.alphaURL)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Installe `AlphaCornerView` sur le « theme frame » de la fenêtre pour passer au-dessus de la barre d'outils.
struct AlphaRibbonInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        DispatchQueue.main.async { Self.install(from: anchor) }
        return anchor
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.install(from: nsView) }
    }

    private static let identifier = NSUserInterfaceItemIdentifier("alphaCornerRibbon")

    private static func install(from anchor: NSView) {
        guard let frame = anchor.window?.contentView?.superview else { return }
        if frame.subviews.contains(where: { $0.identifier == identifier }) { return }
        let side: CGFloat = 140
        let badge = AlphaCornerView(side: side)
        badge.identifier = identifier
        badge.frame = NSRect(x: frame.bounds.width - side, y: frame.bounds.height - side, width: side, height: side)
        badge.autoresizingMask = [.minXMargin, .minYMargin] // épinglé en haut-droite
        frame.addSubview(badge) // dernier subview → au-dessus de tout (titlebar/toolbar comprises)
    }
}

extension View {
    /// Épingle le triangle alpha au coin haut-droit de la fenêtre, au-dessus de tout.
    func alphaRibbon() -> some View {
        background(AlphaRibbonInstaller())
    }
}

/// Écran de blocage affiché lorsque la version alpha a expiré : l'app refuse de fonctionner.
struct AlphaExpiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 52))
                .foregroundStyle(.red)
            Text("Version alpha expirée")
                .font(.title.bold())
            Text("Cette version alpha de GPXManagement a expiré le \(AppConfig.alphaExpiryLabel).\nMerci d'installer une version plus récente pour continuer.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Télécharger une nouvelle version") {
                NSWorkspace.shared.open(AppConfig.alphaURL)
            }
            .controlSize(.large)
            Text("Build \(AppConfig.buildNumber)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 320)
    }
}
