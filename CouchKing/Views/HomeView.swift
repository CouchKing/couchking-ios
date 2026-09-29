import SwiftUI

// Home (Android buildShelvesInto): Hero → Continue Watching → Top 10 Today → For You
// Movies/Shows → the person's shelf lineup in THEIR order, rows filling top-down one after
// another (2.0.82 loading style — no skeletons). Guests get Cinemeta discovery rows.
struct HomeView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [(String, [Meta])] = []
    @State private var top10: [Meta] = []
    @State private var hero: [Meta] = []
    @State private var cw: [CWItem] = []
    @State private var loading = true
    @State private var loadGen = 0
    @State private var resume: CWItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !session.signedIn { GuestBanner() }
                    if !hero.isEmpty { HeroPager(metas: hero) }
                    if !cw.isEmpty {
                        ContinueRow(items: cw) { item in
                            session.dismissNewEpsBadge(item.meta.id, latestAir: item.latestAir)
                            resume = item
                        }
                    }
                    if !top10.isEmpty { Top10Row(metas: top10) }
                    ForEach(rows, id: \.0) { row in
                        PosterRow(title: row.0, metas: row.1)
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                    if !loading && rows.isEmpty && hero.isEmpty {
                        Text(session.hasAddon ? "Nothing to show yet — pull to refresh."
                             : "Sign in with an enabled account for your rows, or browse Discover.")
                            .font(.footnote).foregroundStyle(.secondary).padding(24)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandTitle() }
                if session.profiles.count > 1 {
                    ToolbarItem(placement: .ckTrailing) {
                        Button { session.switchProfile("") } label: {
                            ProfileAvatar(profile: session.profiles.first { $0.id == session.currentProfile }, size: 30)
                        }
                    }
                }
            }
            .ckInlineTitle()
            .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
            // a profile switch or the player exiting → content leaves memory and refills
            .task(id: "\(session.currentProfile)|\(session.homeStale)|\(session.addons.first?.url ?? "")") {
                rows = []; top10 = []; hero = []
                await load()
            }
            // the 60s pull / any state change repaints the Continue row IN PLACE (no page rebuild)
            .onReceive(session.objectWillChange) { _ in
                Task { cw = await session.continueWatchingOrdered() }
            }
            .refreshable { await load() }
            .sheet(item: $resume) { item in
                let p = item.resumeKey.split(separator: ":")
                let s = p.count >= 3 ? Int(p[p.count - 2]) : nil
                let e = p.count >= 3 ? Int(p[p.count - 1]) : nil
                StreamSheet(meta: item.meta, season: s, episode: e, autoplay: true)
                    .ckDetents()
            }
        }
    }

    /// Fill top-down, sequentially, in lineup order (Android 2.0.82 loading style).
    private func load() async {
        loadGen += 1
        let gen = loadGen
        loading = true
        cw = await session.continueWatchingOrdered()
        let (tm, ts) = await Catalog.trending(session: session)
        guard gen == loadGen else { return }
        top10 = Catalog.interleave(tm, ts)
        hero = Array(Catalog.interleave(tm, ts, count: 14).filter { $0.background != nil || $0.poster != nil }.prefix(7))
        var fresh: [(String, [Meta])] = []
        if session.hasAddon {
            for (title, cat) in Catalog.homeLineup(session: session) {
                var metas = await Catalog.shelf(session: session, cat)
                guard gen == loadGen else { return }
                if metas.isEmpty { continue }
                // For You rows keep their ranked order; curated `ids` rows are NEVER shuffled
                if !cat.isForYou && !cat.isOrdered && cat.curated.isEmpty {
                    metas = Catalog.mix(metas, session: session, salt: cat.id)
                }
                fresh.append((title, metas))
                rows = fresh
            }
        } else {
            // tracker For You: addon algo → TMDB rec graph seeded by the library → trending
            let fy = await Catalog.guestForYou(session: session)
            guard gen == loadGen else { return }
            if !fy.isEmpty { fresh.append(("For You", fy)); rows = fresh }
            for (title, type, path) in Catalog.guestRows {
                let metas = await Catalog.guestRow(type, path)
                guard gen == loadGen else { return }
                if metas.isEmpty { continue }
                fresh.append((title, Catalog.mix(metas, session: session, salt: title)))
                rows = fresh
            }
            // curated watch-order shelves work for guests too (Cinemeta-resolved, never shuffled)
            for cat in session.enabledShelves() where !cat.curated.isEmpty {
                let metas = await Catalog.shelf(session: session, cat)
                guard gen == loadGen else { return }
                if !metas.isEmpty { fresh.append((cat.name, metas)); rows = fresh }
            }
        }
        rows = fresh
        loading = false
    }
}

// Rotating trending carousel (Android buildHeroPager): 7 items, swipe, auto-advance every 9s.
struct HeroPager: View {
    let metas: [Meta]
    @State private var page = 0
    @State private var paused = false
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif
    var body: some View {
        #if os(iOS)
        phonePager
        #else
        bigPager
        #endif
    }

    /// Apple TV / Mac: one big card (Firestick idle showcase / desktop hero). Auto-advances every
    /// 9s; pauses while focused (TV) or hovered (Mac); ← → page it (remote edge / arrow buttons).
    private var bigPager: some View {
        let m = metas[min(page, max(0, metas.count - 1))]
        return ZStack {
            NavigationLink(value: m) { HeroCard(meta: m) }
                .ckTile()
                .id(m.id)
                .transition(.opacity)
                #if os(tvOS)
                .focused($focused)
                .onMoveCommand { dir in
                    if dir == .left { step(-1) } else if dir == .right { step(1) }
                }
                #endif
            #if os(macOS)
            HStack {
                arrow("chevron.left") { step(-1) }
                Spacer()
                arrow("chevron.right") { step(1) }
            }
            .padding(.horizontal, 12)
            #endif
        }
        .frame(height: Platform.heroHeight)
        .padding(.horizontal, Platform.gutter)
        #if os(macOS)
        .onHover { paused = $0 }
        #endif
        #if os(tvOS)
        .onChange(of: focused) { f in paused = f }
        #endif
        .task { await rotate() }
    }

    private func step(_ d: Int) {
        guard !metas.isEmpty else { return }
        withAnimation { page = (page + d + metas.count) % metas.count }
    }

    #if os(macOS)
    private func arrow(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.bold()).padding(12)
                .background(.black.opacity(0.5), in: Circle()).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
    #endif

    private func rotate() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(9))
            if !paused, metas.count > 1 { step(1) }
        }
    }

    #if os(iOS)
    private var phonePager: some View {
        TabView(selection: $page) {
            ForEach(Array(metas.enumerated()), id: \.element.id) { i, m in
                NavigationLink(value: m) { HeroCard(meta: m) }.ckTile().tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: 230)
        .padding(.horizontal, 14)
        .simultaneousGesture(DragGesture().onChanged { _ in paused = true }.onEnded { _ in paused = false })
        .task { await rotate() }
    }
    #endif
}

struct HeroCard: View {
    let meta: Meta
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: meta.background ?? meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Theme.card }
            .frame(height: Platform.heroHeight).frame(maxWidth: .infinity).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                if let logo = meta.logo, let u = URL(string: logo) {
                    AsyncImage(url: u) { img in
                        img.resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 44)
                    } placeholder: { Text(meta.name).font(.title3.bold()) }
                    .frame(maxWidth: 200, alignment: .leading)
                } else {
                    Text(meta.name).font(.title3.bold()).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(meta.type == "movie" ? "Movie" : "Show")
                    if let y = meta.releaseInfo { Text("· \(y)") }
                    if let r = meta.imdbRating { Text("· ⭐ \(r)") }
                }
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .titleMenu(meta)
    }
}

struct PosterRow: View {
    let title: String
    let metas: [Meta]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(metas) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }.ckTile()
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

/// Poster tile (Android `poster`): watchlist ✓ badge, watched "done" badge, optional progress
/// bar + "+N" new-episodes badge, long-press context menu. Cached art via URLCache.
struct PosterCard: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    var progress: Double = 0
    var newEps: Int = 0
    var width: CGFloat = 108
    var body: some View {
        let inLib = session.inLibrary(meta.id)
        let done = session.isWatched(meta.id)
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Theme.card.overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if progress > 0.01 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3)).frame(width: width - 12, height: 4)
                        Capsule().fill(Theme.accent).frame(width: (width - 12) * progress, height: 4)
                    }
                    .padding(.bottom, 5)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    if newEps > 0 {
                        Text("+\(newEps)").font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                    }
                    if done {
                        Image(systemName: "checkmark.circle.fill").font(.caption)
                            .foregroundStyle(.white, .green)
                    } else if inLib {
                        Image(systemName: "checkmark.circle.fill").font(.caption)
                            .foregroundStyle(.white, Theme.accent)
                    }
                }
                .padding(5)
            }
            if session.pref("showTitles", true) {
                Text(meta.name).font(.caption2).lineLimit(1).frame(width: width)
                    .foregroundStyle(.primary)
            }
        }
        .titleMenu(meta)
    }
}

// Long-press title menu (Android titleMenu): Details · Add/Remove Library · Mark watched/unwatched ·
// Clear progress — all mutate the synced state in place (tiles repaint, no page rebuild).
struct TitleContextMenu: ViewModifier {
    @EnvironmentObject var session: Session
    let meta: Meta
    func body(content: Content) -> some View {
        content.contextMenu {
            NavigationLink(value: meta) { Label("Details", systemImage: "info.circle") }
            Button(session.inLibrary(meta.id) ? "Remove from Library" : "Add to Library",
                   systemImage: session.inLibrary(meta.id) ? "minus.circle" : "plus.circle") {
                session.toggleLibrary(meta)
            }
            Button(session.isWatched(meta.id) ? "Mark unwatched" : "Mark watched",
                   systemImage: session.isWatched(meta.id) ? "eye.slash" : "checkmark.circle") {
                session.toggleWatched(meta)
            }
            Button("Clear progress", systemImage: "arrow.counterclockwise", role: .destructive) {
                session.clearProgress(meta)
            }
        }
    }
}
extension View { func titleMenu(_ meta: Meta) -> some View { modifier(TitleContextMenu(meta: meta)) } }

// Continue Watching — Android Home CW row: cwOrder-sorted tiles with a resume progress bar and
// the "+N new episodes" badge; TAP RESUMES the right episode directly (resumeFromCw).
struct ContinueRow: View {
    let items: [CWItem]
    let onResume: (CWItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching").font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { item in
                        Button { onResume(item) } label: {
                            PosterCard(meta: item.meta, progress: item.progress, newEps: item.newEps)
                        }
                        .ckTile()
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

// Top 10 Today (Android addTop10Row): big ghost rank numeral behind each poster.
struct Top10Row: View {
    let metas: [Meta]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top 10 Today").font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(Array(metas.enumerated()), id: \.element.id) { idx, m in
                        NavigationLink(value: m) { RankedCard(rank: idx + 1, meta: m) }.ckTile()
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

struct RankedCard: View {
    let rank: Int
    let meta: Meta
    var body: some View {
        HStack(alignment: .bottom, spacing: -16) {
            Text("\(rank)")
                .font(.system(size: 104, weight: .heavy)).italic()
                .foregroundStyle(Theme.card)
                .frame(width: rank >= 10 ? 96 : 58, alignment: .trailing)
            AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Theme.card.overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 96, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .titleMenu(meta)
    }
}

/// Avatar tile tinted by the profile's color (Android profileHue drives the tile everywhere).
struct ProfileAvatar: View {
    let profile: Profile?
    var size: CGFloat = 84
    var body: some View {
        Text(profile?.avatar ?? "🍿").font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(Profile.tint(profile?.color ?? ""), in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

struct GuestBanner: View {
    var body: some View {
        NavigationLink { SettingsView() } label: {
            HStack {
                Text("Sign in to sync your library, history and For You across devices")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
        }
        .ckTile()
    }
}
