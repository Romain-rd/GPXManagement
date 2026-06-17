import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("GPXManagement").font(.title2.bold())
            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                .foregroundStyle(.secondary)
            Text("Application macOS native pour gérer vos fichiers GPS.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
