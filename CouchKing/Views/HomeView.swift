import SwiftUI

// Home (Android buildShelvesInto "Home"): hero carousel → Continue Watching (only when the
// account has an addon, i.e. something can PLAY) → Top 10 Today → For You — Movies / Shows →
// the person's shelf line-up in THEIR order (Settings → Shelves, synced by label), rows filling
// top-down one after another (2.0.82 loading style — no skeletons). Guests get the same stack.
struct HomeView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [(String, [Meta])] = []
    @State private var forYou: [(String, [Meta])] = []
    @State private var top10: [Meta] = []
    @State private var hero: [Meta] = []
    @State private var cw: [CWItem] = []
    @State private var loading = true
    @State private var loadGen = 0
    @State private var resume: CWItem?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !hero.isEmpty { HeroPager(metas: hero) }
                    if session.canStream && !cw.isEmpty {
                        ContinueRow(items: cw) { item in
                            session.dismissNewEpsBadge(item.meta.id, latestAir: item.latestAir)
                            resume = item
                        }
                    }
                    if !top10.isEmpty { Top10Row(metas: top10) }
                    ForEach(forYou, id: \.0) { row in PosterRow(title: row.0, metas: row.1) }
                    ForEach(rows, id: \.0) { row in PosterRow(title: row.0, metas: row.1) }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                    if !loading && rows.isEmpty && forYou.isEmpty && hero.isEmpty {
                        Text("Nothing to show yet — pull to refresh.")
                            .font(.footnote).foregroundStyle(.secondary).padding(24)
                    }
                }
                .padding(.bottom, 28)
                .frame(width: geo.size.width, alignment: .leading)
            }
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandTitle() }
                if session.signedIn, !session.profiles.isEmpty {
                    ToolbarItem(placement: .ckTrailing) {
                        Button { session.switchProfile("") } label: {   // back to "Who's watching?"
                            FaceCircle(profile: session.profiles.first { $0.id == session.currentProfile }, size: 30)
                        }
                    }
                }
            }
            .ckInlineTitle()
            .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
            // a profile switch, the player exiting or the shelf line-up changing → refill
            .task(id: "\(session.currentProfile)|\(session.homeStale)|\(session.addons.first?.url ?? "")|\(session.shelfLabels().joined(separator: ","))") {
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
        cw = session.canStream ? await session.continueWatchingOrdered() : []
        // hero + Top 10 = TODAY's trending movies + shows interleaved (independent of the shelves)
        let (tm, ts) = await Catalog.trending(session: session)
        guard gen == loadGen else { return }
        let mix = Catalog.interleave(tm, ts, count: 40)
        top10 = Array(mix.prefix(10))
        hero = Array(mix.filter { $0.background != nil || $0.poster != nil }.prefix(7))
        // For You — Movies then Shows, always on Home (addon algo → library rec graph → trending)
        let (fyM, fyS) = await Catalog.forYouRows(session: session)
        guard gen == loadGen else { return }
        var fy: [(String, [Meta])] = []
        if !fyM.isEmpty { fy.append(("For You — Movies", fyM)) }
        if !fyS.isEmpty { fy.append(("For You — Shows", fyS)) }
        forYou = fy
        // the shelf line-up, in the person's order
        var fresh: [(String, [Meta])] = []
        rows = []
        for cat in session.enabledShelves() {
            let metas = await Catalog.shelf(session: session, cat)
            guard gen == loadGen else { return }
            if metas.isEmpty { continue }
            fresh.append((cat.name, metas))
            rows = fresh
        }
        rows = fresh
        loading = false
    }
}

// Rotating trending carousel (Android buildHeroPager): 7 items, swipe, auto-advance ~9s.
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

    /// Apple TV / Mac: one big card. Auto-advances every 9s; pauses while focused (TV) or
    /// hovered (Mac); ← → page it (remote edge / arrow buttons).
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
    @State private var dragX: CGFloat = 0
    private var phonePager: some View {
        // HAND-ROLLED pager: a paged TabView inside a vertical ScrollView drifts between
        // pages after re-layout (the "fine at first, then it scooches/centers and cuts off"
        // bug — a known SwiftUI defect). An HStack offset by page*width with a snap drag
        // can't drift: the offset is recomputed from state on every layout.
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            HStack(spacing: 0) {
                ForEach(metas, id: \.id) { m in
                    NavigationLink(value: m) { HeroCard(meta: m) }
                        .buttonStyle(.plain)
                        .frame(width: w, height: Platform.heroHeight)
                        .clipped()
                }
            }
            .offset(x: -CGFloat(page) * w + dragX)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: page)
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { g in paused = true; dragX = g.translation.width }
                    .onEnded { g in
                        let t = g.predictedEndTranslation.width
                        if t < -w / 3 { page = min(page + 1, metas.count - 1) }
                        else if t > w / 3 { page = max(page - 1, 0) }
                        dragX = 0; paused = false
                    }
            )
            // page dots (the TabView used to draw these)
            .overlay(alignment: .bottom) {
                HStack(spacing: 5) {
                    ForEach(metas.indices, id: \.self) { i in
                        Circle().fill(.white.opacity(i == page ? 0.95 : 0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(height: Platform.heroHeight)
        .clipped()
        .task { await rotate() }
    }
    #endif
}

/// One hero slide (Android buildHero): full-bleed art, bottom scrim, logo or name, facts.
struct HeroCard: View {
    let meta: Meta
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: meta.background ?? meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Theme.card }
            .frame(maxWidth: .infinity).frame(height: Platform.heroHeight).clipped()
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
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
        .frame(height: Platform.heroHeight)
        .clipped()
        .titleMenu(meta)
    }
}

/// Android addRow: 17sp bold label, one horizontal strip of posters (up to 60), long-press menu.
struct PosterRow: View {
    let title: String
    let metas: [Meta]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title).font(.system(size: 17, weight: .bold))
                    .padding(.leading, Platform.gutter + 8).padding(.top, 14).padding(.bottom, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Platform.isTV ? 40 : 16) {
                    ForEach(metas.prefix(60)) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }.ckTile()
                    }
                }
                .padding(.horizontal, Platform.gutter + 6)
                .padding(.top, 8).padding(.bottom, Platform.isTV ? 36 : 12)
            }
            .ckFocusSection()
        }
    }
}

/// Poster tile — the EXACT Android `poster()` tile (126×189dp on the phone, r10):
/// • purple ✓ 22dp circle top-RIGHT = in My List
/// • "+N" accent pill top-LEFT = new episodes
/// • yellow-ringed ✓ top-LEFT = watched — dropped BELOW the "+N" pill when both are on
/// • watch bar: dark track + white fill, 4dp, inset 9dp, only for 2–97 %
/// • 12sp medium single-line title under the art (Settings → Titles under posters)
struct PosterCard: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    var progress: Double = 0
    var newEps: Int = 0
    var width: CGFloat = Platform.posterWidth
    private var height: CGFloat { width * 1.5 }
    var body: some View {
        let inLib = session.inLibrary(meta.id)
        let done = session.isWatched(meta.id)
        let pct = Int((progress * 100).rounded())
        VStack(spacing: 2) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Theme.panel.overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
                .frame(width: width, height: height)
                .clipped()
                if (2...97).contains(pct) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.35)).frame(width: width - 18, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(.white)
                            .frame(width: max(6, (width - 18) * CGFloat(pct) / 100), height: 4)
                    }
                    .padding(.leading, 9).padding(.bottom, 9)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if inLib {
                    Text("✓").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if newEps > 0 {
                        Text("+\(newEps)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if done {
                        Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.gold, lineWidth: 1))
                    }
                }
                .padding(6)
            }
            if session.pref("showTitles", true) {
                Text(meta.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .frame(width: width + 8)
                    .foregroundStyle(.primary)
                    .padding(.top, 2)
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
    @State private var menuOpen = false
    func body(content: Content) -> some View {
        #if os(iOS)
        // action SHEET, not contextMenu: the zoomed-tile context menu highlighted the whole
        // card and the rows read badly (AJ: "you can't really tell you're clicking the
        // individual item"). Bottom sheet rows are unmistakable — web mobile does the same.
        // Details = just tap the tile, so it isn't duplicated here.
        content
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in menuOpen = true })
            .confirmationDialog(meta.name, isPresented: $menuOpen, titleVisibility: .visible) {
                Button(session.inLibrary(meta.id) ? "Remove from Library" : "Add to Library") {
                    session.toggleLibrary(meta)
                }
                Button(session.isWatched(meta.id) ? "Mark unwatched" : "Mark watched") {
                    session.toggleWatched(meta)
                }
                Button("Clear progress", role: .destructive) { session.clearProgress(meta) }
                Button("Cancel", role: .cancel) {}
            }
        #else
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
        #endif
    }
}
extension View { func titleMenu(_ meta: Meta) -> some View { modifier(TitleContextMenu(meta: meta)) } }

// Continue Watching — Android Home CW row: cwOrder-sorted tiles with a resume progress bar and
// the "+N new episodes" badge; TAP RESUMES the right episode directly (resumeFromCw).
struct ContinueRow: View {
    let items: [CWItem]
    let onResume: (CWItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Continue Watching").font(.system(size: 17, weight: .bold))
                .padding(.leading, Platform.gutter + 8).padding(.top, 14).padding(.bottom, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Platform.isTV ? 40 : 16) {
                    ForEach(items) { item in
                        Button { onResume(item) } label: {
                            PosterCard(meta: item.meta, progress: item.progress, newEps: item.newEps)
                        }
                        .ckTile()
                    }
                }
                .padding(.horizontal, Platform.gutter + 6)
                .padding(.top, 8).padding(.bottom, Platform.isTV ? 36 : 12)
            }
            .ckFocusSection()
        }
    }
}

// Top 10 Today (Android addTop10Row): a 168dp cell (232dp for #10) with the giant filled ghost
// numeral (118sp, 15 % white with a soft glow) at the bottom-left and the FULL poster at the
// bottom-right — nothing clipped, the poster sits on top of the numeral.
struct Top10Row: View {
    let metas: [Meta]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top 10 Today").font(.system(size: 17, weight: .bold))
                .padding(.leading, Platform.gutter + 6).padding(.top, 14).padding(.bottom, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: Platform.isTV ? 40 : 4) {
                    ForEach(Array(metas.prefix(10).enumerated()), id: \.element.id) { idx, m in
                        NavigationLink(value: m) { RankedCard(rank: idx + 1, meta: m) }.ckTile()
                    }
                }
                .padding(.horizontal, Platform.gutter + 6)
                .padding(.top, 8).padding(.bottom, Platform.isTV ? 36 : 8)
            }
            .ckFocusSection()
        }
    }
}

struct RankedCard: View {
    @EnvironmentObject var session: Session
    let rank: Int
    let meta: Meta
    private var k: CGFloat { Platform.posterWidth / 126 }   // the phone design, scaled for TV / Mac
    var body: some View {
        let cellW = (rank >= 10 ? 232 : 168) * k
        let pw = 126 * k, ph = 189 * k
        let titleH: CGFloat = session.pref("showTitles", true) ? 22 : 0
        ZStack(alignment: .bottomTrailing) {
            // numeral: bottom-START of the cell, drawn first so the poster rides above it
            HStack {
                Text("\(rank)")
                    .font(.system(size: 118 * k, weight: .black))
                    .kerning(-9 * k)
                    .foregroundStyle(.white.opacity(0.15))
                    .shadow(color: .white.opacity(0.7), radius: 1.5)
                    .fixedSize()
                    .padding(.bottom, titleH - 14 * k)
                Spacer(minLength: 0)
            }
            PosterCard(meta: meta, width: pw)
        }
        .frame(width: cellW, height: ph + titleH + 4, alignment: .bottomTrailing)
        .clipped()
        .titleMenu(meta)
    }
}

/// Firestick avatarView / desktop paintAvatar: a circle in the profile hue with the emoji (or
/// the name's initial). Used by the picker, Settings rows and the Home toolbar.
struct FaceCircle: View {
    let profile: Profile?
    var size: CGFloat = 84
    var glyph: String? = nil      // override while editing (the form's live preview)
    var tint: String? = nil
    var body: some View {
        let g = glyph ?? profile?.glyph ?? "G"
        Text(g.isEmpty ? "?" : g).font(.system(size: size * 0.42)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background((tint.flatMap { $0.isEmpty ? nil : Profile.tint($0) }) ?? Profile.hue(profile), in: Circle())
    }
}

/// Kept for the phone screens that still pass a square avatar tile.
struct ProfileAvatar: View {
    let profile: Profile?
    var size: CGFloat = 84
    var body: some View { FaceCircle(profile: profile, size: size) }
}
