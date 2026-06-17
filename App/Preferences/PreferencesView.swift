import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("Général", systemImage: "gearshape") }
            OrganizationPreferencesView()
                .tabItem { Label("Organisation iCloud", systemImage: "folder") }
            MaintenanceView()
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
            StravaPreferencesView()
                .tabItem { Label("Strava", systemImage: "arrow.triangle.2.circlepath") }
            AboutView()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        // Assez grand pour les onglets denses (Maintenance, Strava) ; les Form défilent au-delà.
        .frame(width: 580, height: 600)
    }
}





