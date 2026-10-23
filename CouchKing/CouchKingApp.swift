import SwiftUI
#if os(iOS)
import UIKit
import UserNotifications
#endif

// CouchKing iOS — mirror of the Android app (2.0.93 feature line).
// Tracker-mode for guests; streaming appears only when the signed-in account
// has an addon attached (on any device — it syncs down with the account state).
@main
struct CouchKingApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CKAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var session = Session.shared
    @Environment(\.scenePhase) private var scenePhase
    init() {
        CrashGuard.install()   // previous run's crash trace → /tvapp/crash → TG
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
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhaseR
    @State private var notifNudge = false        // show the "open Settings" card (already denied)
    @State private var notifPromptDone = false    // once per launch
    #endif

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
        // repaint the whole tree when the per-profile accent changes (load / switch / pick).
        // themeTick only moves on those events, so this never churns during normal use.
        .id(session.themeTick)
        .onChange(of: session.signedIn) { on in if !on { firstRun = .none } }
        #if os(iOS)
        // NOTIFICATION ASK ON OPEN (AJ Oct 23 "I want the prompt when I open and allow, like
        // everything else — not go dig in Settings"). iOS only shows its SYSTEM popup once ever,
        // so: not-yet-asked → fire the system Allow/Deny prompt; already-denied → an in-app card
        // whose Allow button jumps straight into CouchKing's notification settings (the only path
        // iOS leaves). Runs on open and each return to foreground, once per launch.
        .task { checkNotifPrompt() }
        .onChange(of: scenePhaseR) { phase in if phase == .active { checkNotifPrompt() } }
        .alert("Turn on notifications", isPresented: $notifNudge) {
            Button("Allow") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("So CouchKing can tell you about new episodes and game reminders. You stay in control — episode alerts only send for shows you turn on.")
        }
        #endif
    }

    #if os(iOS)
    /// Decide what (if anything) to do about notification permission on open. Once per launch.
    private func checkNotifPrompt() {
        guard session.signedIn, !notifPromptDone else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                guard !notifPromptDone else { return }
                notifPromptDone = true
                switch s.authorizationStatus {
                case .notDetermined: Push.register()   // first time → system Allow/Deny prompt
                case .denied:        notifNudge = true  // can't re-prompt → one tap into Settings
                default: break                          // authorized / provisional → already on
                }
            }
        }
    }
    #endif

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
    @State private var tab = 1   // default Home; overridden by the landingTab pref on cold open
    @State private var landed = false

    /// Tab tag the `landingTab` pref maps to (Android showMain(landingTab)): Home / Live TV /
    /// Library. Live TV falls back to Home when the tab isn't available for this account.
    private func landingTag() -> Int {
        switch session.pref("landingTab", "Home") {
        case "Live TV": return (session.liveTvOn && session.canStream) ? 4 : 1
        case "Library": return 3
        default: return 1
        }
    }
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
    // Android's bottom nav shows EVERY tab in one row. Native SwiftUI TabView collapses the
    // 6th item into a "More" tab (the "…" AJ saw once Live TV appears) — so we draw our own
    // compact bar that fits all of them (Android navTabs parity).
    private struct NavItem { let tag: Int; let label: String; let icon: String }
    private var navItems: [NavItem] {
        var items = [NavItem(tag: 0, label: "Search", icon: "magnifyingglass"),
                     NavItem(tag: 1, label: "Home", icon: "house.fill"),
                     NavItem(tag: 2, label: "Discover", icon: "square.grid.2x2.fill"),
                     NavItem(tag: 3, label: "Library", icon: "books.vertical.fill")]
        if session.liveTvOn && session.canStream {
            items.append(NavItem(tag: 4, label: "Live TV", icon: "dot.radiowaves.left.and.right"))
        }
        items.append(NavItem(tag: 5, label: "Settings", icon: "gearshape.fill"))
        return items
    }

    private var phoneTabs: some View {
        VStack(spacing: 0) {
            ZStack {
                switch tab {
                case 0: SearchView()
                case 2: DiscoverTab()
                case 3: LibraryView()
                case 4: LiveTVView()
                case 5: SettingsView()
                default: HomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Theme.card2)
            HStack(spacing: 0) {
                ForEach(navItems, id: \.tag) { it in
                    Button { tab = it.tag } label: {
                        VStack(spacing: 3) {
                            Image(systemName: it.icon).font(.system(size: 19))
                            Text(it.label).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(tab == it.tag ? Theme.accent : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 7)
            .padding(.horizontal, 4)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .onAppear { if !landed { landed = true; tab = landingTag() } }
    }
    #endif
}

// Palette = the Android app's (res/colors.xml brand_bg + MainActivity fg/dim/card/accent):
// bg #0C0B14, panel #1B1830, card #2C2649, accent #7B5BF5, dim #A9A5C0.
enum Theme {
    // Per-profile accent (Android Store.accentColor): defaults to Royal #7B5BF5, overridden
    // live by applyAccent(hex) when a profile's `accentColor` pref loads. A `var` so the whole
    // tree can repaint onto a new hue (RootView keys its body on session.themeTick).
    static var accent = Color(hex: "#7B5BF5")   // #7B5BF5 Royal (default)
    /// Set the app-wide accent from a hex string; blank/nil/invalid keeps the Royal default.
    static func applyAccent(_ hex: String?) {
        let h = (hex ?? "").trimmingCharacters(in: .whitespaces)
        accent = h.isEmpty ? Color(hex: "#7B5BF5") : Color(hex: h)
    }
    /// The 8 pickable accents — identical to Android's list (MainActivity L8141): name + hex
    /// round-trip across devices (Android's default name is "Royal (default)"). A struct (not a
    /// tuple) so ForEach can key on \.hex — Swift has no key paths into tuple elements.
    struct AccentChoice: Identifiable { let name: String; let hex: String; var id: String { hex } }
    static let accentChoices: [AccentChoice] = [
        .init(name: "Royal (default)", hex: "#7B5BF5"), .init(name: "Gold", hex: "#E0A400"),
        .init(name: "Ocean", hex: "#2E86F5"), .init(name: "Crimson", hex: "#E23B4E"),
        .init(name: "Emerald", hex: "#1DB954"), .init(name: "Pink", hex: "#E754A6"),
        .init(name: "Sunset", hex: "#F0702A"), .init(name: "Teal", hex: "#18B8A8")]
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

extension Color {
    /// `Color(hex: "#7B5BF5")` — 6-digit RGB (with or without leading '#'); invalid → Royal.
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else {
            self = Color(red: 0x7B / 255.0, green: 0x5B / 255.0, blue: 0xF5 / 255.0); return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255.0,
                     green: Double((v >> 8) & 0xFF) / 255.0,
                     blue: Double(v & 0xFF) / 255.0)
    }
}

/// The title-bar brand: logo + "CouchKing" (Android brandSpan: "Couch" purple, "King" white).
struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("Logo").resizable().aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 0) {
                Text("Couch").foregroundStyle(Theme.couch)
                Text("King").foregroundStyle(Theme.king)
            }
            .font(.headline.bold())
        }
    }
}
