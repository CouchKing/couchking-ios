import SwiftUI

// CouchKing iOS — mirror of the Android app (2.0.93 feature line).
// Tracker-mode for guests; streaming appears only when the signed-in account
// has an addon assigned server-side (nothing baked into the binary).
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

struct RootView: View {
    @EnvironmentObject var session: Session
    @AppStorage("onboarded") private var onboarded = false
    var body: some View {
        if let gate = session.updateRequired {
            UpdateGateView(info: gate)   // below the service's minVersion: nothing else opens
        } else if !onboarded {
            OnboardingView { onboarded = true }
        } else if session.needsProfilePick {
            ProfilePickerView()
        } else {
            MainTabs()
        }
    }
}

// First-launch welcome + Terms/Privacy acceptance (Apple requires a clear terms gate; guest mode
// starts only after accepting) — Android showOnboarding/gate parity.
struct OnboardingView: View {
    let done: () -> Void
    var body: some View {
        NavigationStack { onboarding }
    }
    private var onboarding: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("👑").font(.system(size: 64))
            Text("CouchKing").font(.largeTitle.bold())
            Text("Movies, shows, and live TV — synced across your devices.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    done()
                } label: {
                    Text("Get Started").font(.headline).frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Text("By continuing you agree to our")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    NavigationLink("Terms") { LegalTextView(title: "Terms of Service", text: Legal.terms) }
                    Text("·").foregroundStyle(.secondary)
                    NavigationLink("Privacy Policy") { LegalTextView(title: "Privacy Policy", text: Legal.privacy) }
                }.font(.caption2)
            }
            .padding(.horizontal, 28).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

struct MainTabs: View {
    @EnvironmentObject var session: Session
    @State private var tab = 1   // Home is the landing tab (Android opens on Home)
    var body: some View {
        #if os(macOS)
        DesktopShell()
        #elseif os(tvOS)
        // Firestick / Android TV top navigation: Home first, then Search · Discover · Library ·
        // [Live TV] · Settings — the remote lands on Home.
        TabView(selection: $tab) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(1)
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(0)
            DiscoverTab().tabItem { Label("Discover", systemImage: "square.grid.2x2.fill") }.tag(2)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(3)
            if session.liveTvOn {
                LiveTVView().tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }.tag(4)
            }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(5)
        }
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
            if session.liveTvOn {
                LiveTVView().tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }.tag(4)
            }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(5)
        }
    }
    #endif
}

#if os(macOS)
/// The desktop (Electron) layout: a left sidebar with the same sections, content on the right.
/// Each section keeps its own navigation stack, so going back returns to where you were.
struct DesktopShell: View {
    @EnvironmentObject var session: Session
    enum Section: String, Hashable, CaseIterable {
        case home = "Home", search = "Search", discover = "Discover", library = "Library"
        case live = "Live TV", settings = "Settings"
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .search: return "magnifyingglass"
            case .discover: return "square.grid.2x2.fill"
            case .library: return "books.vertical.fill"
            case .live: return "dot.radiowaves.left.and.right"
            case .settings: return "gearshape.fill"
            }
        }
    }
    @State private var section: Section? = .home

    private var sections: [Section] {
        Section.allCases.filter { $0 != .live || session.liveTvOn }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(sections, id: \.self) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .top) {
                BrandTitle().padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
        } detail: {
            switch section ?? .home {
            case .home: HomeView()
            case .search: SearchView()
            case .discover: DiscoverTab()
            case .library: LibraryView()
            case .live: LiveTVView()
            case .settings: SettingsView()
            }
        }
        .onChange(of: session.liveTvOn) { on in if !on && section == .live { section = .home } }
    }
}
#endif

// Palette aligned with Android + the Sheets.kt components: accent #7B5BF5, panel #1B1830,
// card #2C2649 (the iOS-only #A855F7 accent is gone so every surface reads the same).
enum Theme {
    static let accent = Color(red: 0x7B / 255.0, green: 0x5B / 255.0, blue: 0xF5 / 255.0)   // #7B5BF5
    static let bg = Color(red: 0.03, green: 0.03, blue: 0.06)
    static let panel = Color(red: 0x1B / 255.0, green: 0x18 / 255.0, blue: 0x30 / 255.0)    // #1B1830
    static let card = Color(red: 0x2C / 255.0, green: 0x26 / 255.0, blue: 0x49 / 255.0)     // #2C2649
    /// Brand gradient (Android's crown/gradient span on "CouchKing").
    static let brand = LinearGradient(colors: [accent, Color(red: 0.93, green: 0.45, blue: 0.85)],
                                      startPoint: .leading, endPoint: .trailing)
}

/// "👑 CouchKing" — the brand span Android draws on every title bar (~L5991).
struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("👑")
            Text("CouchKing").font(.headline.bold()).foregroundStyle(Theme.brand)
        }
    }
}
