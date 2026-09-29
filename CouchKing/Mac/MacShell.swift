#if os(macOS)
import SwiftUI

// `#shell` (index.html / style.css 32-50): a Firestick-style rail on the left that expands on
// pointer hover (64 → 200px, .18s; icons stay, labels fade + slide in from −6px after 50ms) and
// PUSHES the content (flex sibling, not an overlay). Items top→bottom: brand, profile, Search,
// Home (default), Discover, Library, [Live TV], Settings. No Downloads (App Store build).
struct MacShell: View {
    @EnvironmentObject var session: Session
    enum Nav: String, CaseIterable, Hashable {
        case search = "Search", home = "Home", discover = "Discover", library = "Library"
        case live = "Live TV", settings = "Settings"
        var icon: String {
            switch self {
            case .search: return "🔍"
            case .home: return "🏠"
            case .discover: return "🧭"
            case .library: return "📚"
            case .live: return "📺"
            case .settings: return "⚙️"
            }
        }
    }
    @State private var nav: Nav = .home
    @State private var open = false

    var body: some View {
        HStack(spacing: 0) {
            rail
            ZStack {
                Desk.bg.ignoresSafeArea()
                page
            }
        }
        .background(Desk.bg)
        .overlay { DeskToastView() }
        .toolbar(.hidden, for: .windowToolbar)
        .onChange(of: session.liveTvOn) { on in if !on && nav == .live { nav = .home } }
    }

    private var items: [Nav] { Nav.allCases.filter { $0 != .live || session.liveTvOn } }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 5.6) {
            // `.rail-brand`
            HStack(spacing: 9.6) {
                Text("👑").font(.system(size: 22)).frame(width: 30, height: 30)
                DeskWordmark().opacity(open ? 1 : 0).offset(x: open ? 0 : -6)
            }
            .padding(.horizontal, 8).padding(.top, 6.4).padding(.bottom, 16)
            // profile item: avatar circle in the profile colour (opens the "Who's watching?" gate)
            railItem(icon: AnyView(profileIcon), label: profileName, selected: false) {
                if session.signedIn && session.profiles.count > 1 { session.switchProfile("") }
                else { nav = .settings }
            }
            ForEach(items, id: \.self) { n in
                railItem(icon: AnyView(Text(n.icon).font(.system(size: 18.4)).saturation(0.7)),
                         label: n.rawValue, selected: nav == n) { nav = n }
            }
            Spacer()
        }
        .padding(.vertical, 16).padding(.horizontal, 8.8)
        .frame(width: open ? Desk.railOpen : Desk.rail, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(open ? Desk.railBg : Color.clear)
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: open)
        .onHover { open = $0 }
        .zIndex(20)
    }

    private var profileName: String {
        guard session.signedIn else { return "Guest" }
        return session.profiles.first { $0.id == session.currentProfile }?.name ?? "Profile"
    }

    @ViewBuilder private var profileIcon: some View {
        if let p = session.profiles.first(where: { $0.id == session.currentProfile }) {
            Text(p.avatar).font(.system(size: 14)).frame(width: 24, height: 24)
                .background(Profile.tint(p.color), in: Circle())
        } else {
            Text("👤").font(.system(size: 18.4))
        }
    }

    /// `.rail-item`: 12px radius, muted → white; the selected pill (#332D55) only while expanded.
    private func railItem(icon: AnyView, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Hovering { hover in
                HStack(spacing: 12.8) {
                    icon.frame(width: 24)
                    Text(label).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        .opacity(open ? 1 : 0).offset(x: open ? 0 : -6)
                        .animation(.easeOut(duration: 0.15).delay(0.05), value: open)
                }
                .foregroundStyle(selected || hover ? Desk.fg : Desk.muted)
                .padding(.horizontal, 11.2).padding(.vertical, 10.9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected && open ? Desk.menuHover : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var page: some View {
        switch nav {
        case .home: MacStack { MacHome() }
        case .search: MacStack { MacSearch() }
        case .discover: MacStack { MacDiscover() }
        case .library: MacStack { MacLibrary() }
        case .live: MacStack { LiveTVView() }
        case .settings: SettingsView()
        }
    }
}

/// A section's navigation stack with the desktop's in-page pages (details, person, episode).
/// No window toolbar — pages carry their own "‹ Back" (desktop has no global top bar).
struct MacStack<Root: View>: View {
    @ViewBuilder let root: () -> Root
    var body: some View {
        NavigationStack {
            root()
                .navigationDestination(for: Meta.self) { MacDetail(meta: $0) }
                .navigationDestination(for: TMDB.Person.self) { MacPerson(person: $0) }
        }
    }
}

/// `‹ Back` — ghost small button (detail / person / episode pages).
struct DeskBack: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button("‹ Back") { dismiss() }.buttonStyle(DeskButton(kind: .ghost, small: true))
    }
}
#endif
