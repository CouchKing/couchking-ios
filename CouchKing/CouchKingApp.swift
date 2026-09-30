import SwiftUI

// CouchKing iOS — mirror of the Android app (2.0.93 feature line).
// Tracker-mode for guests; streaming appears only when the signed-in account
// has an addon attached (on any device — it syncs down with the account state).
@main
struct CouchKingApp: App {
    @StateObject private var session = Session.shared
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // Poster/image discipline (Android: 300MB disk poster cache + viewport art pass):
        // one shared cache so scrolling back through rows never re-fetches artwork.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 300 * 1024 * 1024)
        // video app audio session: playback category so PiP + background audio work
        PlaybackAudio.configure()
    }
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
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)   // desktop app: resizable, never cramped
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 860)
        .commands {
            // no document model — drop "New Window" style clutter; the app is one library window
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}

/// Android profileGate, as a view tree:
/// update gate → LOGIN (nobody signed in, nobody chose guest) → first profile ("Create your
/// profile" → "Pick your shelves") → "Who's watching?" → the app.
struct RootView: View {
    @EnvironmentObject var session: Session
    enum FirstRun { case none, shelves }
    @State private var firstRun: FirstRun = .none

    var body: some View {
        Group {
            if let gate = session.updateRequired {
                UpdateGateView(info: gate)   // below the service's minVersion: nothing else opens
            } else if !session.signedIn && !session.onboarded {
                LoginView()
            } else if session.needsProfileCreate {
                firstProfile
            } else if firstRun == .shelves {
                firstShelves
            } else if session.needsProfilePick {
                ProfilePickerView()
            } else {
                MainTabs()
            }
        }
        .onChange(of: session.signedIn) { on in if !on { firstRun = .none } }
    }

    // "Create your profile" (Android showProfileCreate(first = true)): THEY name it, then pick
    // their Home shelves, then land on Home.
    private var firstProfile: some View {
        NavigationStack {
            #if os(tvOS) || os(macOS)
            ProfileFormHub(profile: nil, first: true) { firstRun = .shelves }
            #else
            ProfileEditView(profile: nil, first: true) { firstRun = .shelves }
            #endif
        }
    }

    private var firstShelves: some View {
        NavigationStack {
            #if os(tvOS) || os(macOS)
            HubShelves(onDone: { session.push(); firstRun = .none })
            #else
            ShelfPickerView(onDone: { session.push(); firstRun = .none })
            #endif
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var session: Session
    @State private var tab = 1   // Home is the landing tab (Android opens on Home)
    var body: some View {
        #if os(macOS)
        MacShell()   // the desktop app's hover rail (reference/desktop)
        #elseif os(tvOS)
        TVShell()   // the Firestick leanback rail + board (reference/android-tv)
        #else
        phoneTabs
        #endif
    }

    #if os(iOS)
    private var phoneTabs: some View {
        // Android mobile navTabs order: Search · Home · Discover · Library · [Live TV] · Settings
        TabView(selection: $tab) {
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(0)
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(1)
            DiscoverTab().tabItem { Label("Discover", systemImage: "square.grid.2x2.fill") }.tag(2)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(3)
            // Live TV exists ONLY once an addon with a `tv` catalog is attached — the shell
            // itself never mentions it (Android navTabs / desktop livetvDetect)
            if session.liveTvOn && session.canStream {
                LiveTVView().tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }.tag(4)
            }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(5)
        }
    }
    #endif
}

// Palette = the Android app's (res/colors.xml brand_bg + MainActivity fg/dim/card/accent):
// bg #0C0B14, panel #1B1830, card #2C2649, accent #7B5BF5, dim #A9A5C0.
enum Theme {
    static let accent = Color(red: 0x7B / 255.0, green: 0x5B / 255.0, blue: 0xF5 / 255.0)   // #7B5BF5
    static let bg = Color(red: 0x0C / 255.0, green: 0x0B / 255.0, blue: 0x14 / 255.0)       // brand_bg
    static let panel = Color(red: 0x1B / 255.0, green: 0x18 / 255.0, blue: 0x30 / 255.0)    // #1B1830
    static let card = Color(red: 0x2C / 255.0, green: 0x26 / 255.0, blue: 0x49 / 255.0)     // #2C2649
    static let card2 = Color(red: 0x24 / 255.0, green: 0x1F / 255.0, blue: 0x3D / 255.0)    // #241F3D
    static let dim = Color(red: 0xA9 / 255.0, green: 0xA5 / 255.0, blue: 0xC0 / 255.0)      // #A9A5C0
    static let gold = Color(red: 0xF5 / 255.0, green: 0xC5 / 255.0, blue: 0x18 / 255.0)     // #F5C518
    static let couch = Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0)    // brandSpan "Couch"
    static let king = Color(red: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF5 / 255.0)     // brandSpan "King"
    /// Brand gradient (Android's crown/gradient span on "CouchKing").
    static let brand = LinearGradient(colors: [accent, Color(red: 0.93, green: 0.45, blue: 0.85)],
                                      startPoint: .leading, endPoint: .trailing)
}

/// The title-bar brand: logo + "CouchKing TV" (Android brandSpan: "Couch" purple, "King" white).
struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("Logo").resizable().aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 0) {
                Text("Couch").foregroundStyle(Theme.couch)
                Text("King TV").foregroundStyle(Theme.king)
            }
            .font(.headline.bold())
        }
    }
}
