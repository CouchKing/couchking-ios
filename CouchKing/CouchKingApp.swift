import SwiftUI

// CouchKing iOS — mirror of the Android app (2.0.93 feature line).
// Tracker-mode for guests; streaming appears only when the signed-in account
// has an addon assigned server-side (nothing baked into the binary).
@main
struct CouchKingApp: App {
    @StateObject private var session = Session.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await session.boot() }
                // Android onResume parity: every foreground silently pulls state, refreshes
                // cached expiry, picks up a just-assigned addon, and re-detects Live TV.
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await session.foregroundResume() } }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        if session.needsProfilePick {
            ProfilePickerView()
        } else {
            MainTabs()
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var session: Session
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical.fill") }
            if session.liveTvOn {
                LiveTVView().tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }
            }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.66, green: 0.33, blue: 0.97)   // Android's #A855F7
    static let bg = Color(red: 0.03, green: 0.03, blue: 0.06)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.14)
}
