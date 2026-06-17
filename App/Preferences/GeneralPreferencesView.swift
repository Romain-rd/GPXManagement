import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct GeneralPreferencesView: View {
    @AppStorage("defaultMapLayer") private var mapLayer: String = MapLayer.ignScan25.rawValue
    @AppStorage("photosSelectedByDefault") private var photosSelectedByDefault = true
    @AppStorage("pauseThresholdMinutes") private var pauseThresholdMinutes: Double = 5
    @AppStorage("pauseRadiusMeters") private var pauseRadiusMeters: Double = 40

    var body: some View {
        Form {
            Section("Carte") {
                Picker("Couche carte par défaut", selection: $mapLayer) {
                    ForEach(MapLayer.allCases.filter { !$0.isOverlayOnly }) { layer in
                        Text(layer.displayName).tag(layer.rawValue)
                    }
                }
            }
            Section("Métriques — détection des pauses") {
                Stepper("Durée minimale d'une pause : \(Int(pauseThresholdMinutes)) min",
                        value: $pauseThresholdMinutes, in: 1...60, step: 1)
                Stepper("Rayon d'immobilité : \(Int(pauseRadiusMeters)) m",
                        value: $pauseRadiusMeters, in: 10...150, step: 5)
                Text("Un arrêt est une pause si l'on reste dans ce rayon pendant au moins cette durée (robuste au tremblement GPS ; les arrêts brefs — feu rouge, photo — sont ignorés).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Photos") {
                Toggle("Photos sélectionnées par défaut", isOn: $photosSelectedByDefault)
                Text("À la première mise en relation d'une activité avec des photos proches (±30 min), elles sont affichées par défaut. Décochez pour qu'elles soient masquées tant que vous ne les sélectionnez pas.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
