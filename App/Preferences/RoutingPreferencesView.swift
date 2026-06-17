import SwiftUI

/// Préférences de routage : fournisseur par défaut + clés API perso (avec aide pour les obtenir).
struct RoutingPreferencesView: View {
    @AppStorage("routingProvider") private var providerRaw = RoutingProvider.mapkit.rawValue
    @AppStorage("orsApiKey") private var orsKey = ""
    @AppStorage("graphHopperApiKey") private var graphHopperKey = ""

    private var provider: RoutingProvider { RoutingProvider(rawValue: providerRaw) ?? .mapkit }

    var body: some View {
        Form {
            Section("Fournisseur de routage") {
                Picker("Fournisseur", selection: $providerRaw) {
                    ForEach(RoutingProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text(provider.note).font(.caption).foregroundStyle(.secondary)
                if provider.needsKey, currentKeyMissing {
                    Label("Ce fournisseur nécessite une clé API (ci-dessous). Sans clé, le routage bascule sur le repli BRouter.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Clés API") {
                keyRow("OpenRouteService", text: $orsKey, help: RoutingProvider.ors.helpURL)
                keyRow("GraphHopper", text: $graphHopperKey, help: RoutingProvider.graphhopper.helpURL)
                Text("Les clés restent sur cet appareil (non synchronisées, jamais partagées). Apple Plans, IGN, BRouter et Ligne droite n'en demandent pas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Profil") {
                Text("Le profil de déplacement (à pied / vélo / route & moto / ligne droite) se choisit par parcours, dans la barre d'outils de l'éditeur d'itinéraire.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var currentKeyMissing: Bool {
        switch provider {
        case .ors: return orsKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .graphhopper: return graphHopperKey.trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    @ViewBuilder private func keyRow(_ name: String, text: Binding<String>, help: URL?) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                SecureField("Clé API", text: text).frame(minWidth: 220)
                if let help {
                    Link(destination: help) { Image(systemName: "questionmark.circle") }
                        .help("Obtenir une clé \(name)")
                }
            }
        }
    }
}
