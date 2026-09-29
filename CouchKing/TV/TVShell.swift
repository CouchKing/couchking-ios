#if os(tvOS)
import SwiftUI

// Firestick shell (showMain ~1059, railView ~1396): a left icon RAIL floating over the board.
// Collapsed: 64dp, transparent, entries vertically centered, selected tab = white icon, others
// #A9A5C0, no labels. Any rail entry focused → snaps (no animation) to 190dp on #EE0D0B18 with
// labels (15.5sp), the wordmark, and a #332D55 pill behind the selected tab.
// Order: Search · Home · Discover · Library · [Live TV] · Settings (last tab saved, else Home).
// Menu/BACK: pops the page → non-Home tab goes Home (Live TV returns to where you came from) →
// Home focuses the rail → from the rail, the system exits the app.
struct TVShell: View {
    @EnvironmentObject var session: Session
    enum Tab: String, CaseIterable, Hashable {
        case search = "Search", home = "Home", discover = "Discover", library = "Library"
        case live = "Live TV", settings = "Settings"
        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .home: return "house.fill"
            case .discover: return "safari.fill"
            case .library: return "books.vertical.fill"
            case .live: return "tv"
            case .settings: return "gearshape.fill"
            }
        }
    }
    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "lastTab") ?? "") ?? .home
    @State private var cameFrom: Tab = .home
    @State private var paths: [Tab: NavigationPath] = [:]
    @FocusState private var railFocus: String?      // "profile" or a Tab rawValue

    private var expanded: Bool { railFocus != nil }
    private var tabs: [Tab] { Tab.allCases.filter { $0 != .live || session.liveTvOn } }
    private var atRoot: Bool { (paths[tab]?.count ?? 0) == 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            TV.bg.ignoresSafeArea()
            page
            if tab != .settings { rail }   // Settings is a full-screen page with no rail
        }
        .onExitCommand(perform: interceptExit ? handleExit : nil)
        .onChange(of: session.liveTvOn) { on in if !on && tab == .live { select(.home) } }
    }

    // MARK: pages
    @ViewBuilder private var page: some View {
        let path = Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
        NavigationStack(path: path) {
            Group {
                switch tab {
                case .home: TVHome()
                case .search: TVSearch()
                case .discover: TVDiscover()
                case .library: TVLibrary()
                case .live: LiveTVView()
                case .settings: SettingsView(embedded: true)
                }
            }
            .navigationDestination(for: Meta.self) { TVDetail(meta: $0) }
            .navigationDestination(for: TMDB.Person.self) { TVPerson(person: $0) }
        }
        .id(tab)
    }

    // MARK: rail
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(spacing: TV.dp(10)) {
                Text("👑").font(.system(size: TV.dp(28))).frame(width: TV.dp(36), height: TV.dp(36))
                if expanded { TVWordmark() }
            }
            .padding(.leading, TV.dp(6)).padding(.bottom, TV.dp(18))
            if session.signedIn { profileEntry.padding(.bottom, TV.dp(14)) }
            ForEach(tabs, id: \.self) { t in tabEntry(t).padding(.vertical, TV.dp(10)) }
            Spacer()
        }
        .padding(.horizontal, TV.dp(8)).padding(.vertical, TV.dp(18))
        .frame(width: TV.dp(expanded ? 190 : 64), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(expanded ? TV.railOpen : .clear)
        .focusSection()
        .ignoresSafeArea()
    }

    private var profileEntry: some View {
        let p = session.profiles.first { $0.id == session.currentProfile }
        return Button { session.switchProfile("") } label: {
            HStack(spacing: TV.dp(11)) {
                Text(p?.avatar ?? String((p?.name ?? "P").prefix(1))).font(.system(size: TV.sp(12)))
                    .frame(width: TV.dp(26), height: TV.dp(26))
                    .background(Profile.tint(p?.color ?? ""), in: Circle())
                if expanded {
                    Text(p?.name ?? "Profile").font(.system(size: TV.sp(15.5))).foregroundStyle(TV.dim).lineLimit(1)
                }
            }
            .padding(.leading, TV.dp(11)).padding(.trailing, TV.dp(12)).padding(.vertical, TV.dp(9))
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(TVRingButton(radius: TV.dp(12)))
        .focused($railFocus, equals: "profile")
    }

    private func tabEntry(_ t: Tab) -> some View {
        let selected = tab == t
        return Button { select(t) } label: {
            HStack(spacing: TV.dp(13)) {
                Image(systemName: t.icon).font(.system(size: TV.dp(18)))
                    .frame(width: TV.dp(22), height: TV.dp(22))
                    .foregroundStyle(selected ? .white : TV.dim)
                if expanded {
                    Text(t.rawValue).font(.system(size: TV.sp(15.5), weight: selected ? .bold : .regular))
                        .foregroundStyle(selected ? .white : TV.dim).lineLimit(1)
                }
            }
            .padding(.leading, TV.dp(13)).padding(.trailing, TV.dp(12)).padding(.vertical, TV.dp(11))
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            .background(selected && expanded ? TV.railSelected : .clear, in: RoundedRectangle(cornerRadius: TV.dp(12)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(12)))
        .focused($railFocus, equals: t.rawValue)
    }

    private func select(_ t: Tab) {
        if t == .live && tab != .live { cameFrom = tab }
        if t == .home { paths[.home] = NavigationPath() }   // Home resets to the top
        tab = t
        if t != .settings { UserDefaults.standard.set(t.rawValue, forKey: "lastTab") }
    }

    // MARK: Menu / BACK
    /// Intercept only at a tab's root; deeper pages pop through the navigation stack, and on
    /// Home with the rail already focused the system handles it (exits the app).
    private var interceptExit: Bool {
        guard atRoot else { return false }
        if tab == .home { return railFocus == nil }
        return true
    }
    private func handleExit() {
        switch tab {
        case .home: railFocus = Tab.home.rawValue
        case .live: select(cameFrom == .live ? .home : cameFrom)
        default: select(.home)
        }
    }
}
#endif
