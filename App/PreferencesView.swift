import SwiftUI
import GPXCore

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("Général", systemImage: "gearshape") }
            OrganizationPreferencesView()
                .tabItem { Label("Organisation iCloud", systemImage: "folder") }
            StravaPreferencesView()
                .tabItem { Label("Strava", systemImage: "arrow.triangle.2.circlepath") }
            AboutView()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
    }
}

struct GeneralPreferencesView: View {
    @AppStorage("defaultMapLayer") private var mapLayer: String = "ign_scan25"

    var body: some View {
        Form {
            Picker("Couche carte par défaut", selection: $mapLayer) {
                Text("IGN — Scan 25").tag("ign_scan25")
                Text("IGN — Plan v2").tag("ign_planv2")
                Text("IGN — Pentes").tag("ign_slopes")
                Text("Apple — Standard").tag("mapkit_standard")
                Text("Apple — Satellite").tag("mapkit_satellite")
            }
        }
        .padding()
    }
}

struct OrganizationPreferencesView: View {
    @AppStorage("organizationPattern") private var pattern: String = OrganizationPattern.default.template

    var body: some View {
        Form {
            Picker("Modèle prédéfini", selection: $pattern) {
                ForEach(OrganizationPattern.presets, id: \.template) { preset in
                    Text(preset.label).tag(preset.template)
                }
            }
            TextField("Modèle personnalisé", text: $pattern, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(.body, design: .monospaced))
            Text("Variables : {year}, {month}, {day}, {activity}, {subactivity}, {title}, {ext}")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Réorganiser maintenant") {}
                    .disabled(true)
                    .help("Fonctionnalité prévue après P5")
            }
        }
        .padding()
    }
}

struct StravaPreferencesView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Synchronisation Strava").font(.title3)
            Text("Disponible en P8 (Strava sync).")
                .foregroundStyle(.secondary)
            Button("Connecter Strava") {}
                .disabled(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

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
