import SwiftUI

// Live TV (IOS_CONTRACTS §2e / Android buildLiveTv + liveRenderGuide), top → bottom:
// title + region chip · live-games banner (3-min self-refresh) · search (350ms) · category chips
// (Guide / ★ Favorites / sections / Local / 24/7 / All Channels) · body — the guide grid with
// day tabs, the ↻ recent strip, ★ favorites first then SECTION headers, a shared timeline at
// 4px/min with the current programme highlighted and a red now-line; long-press = ★ toggle.
// Staleness: pages older than 60s rebuild on foreground; the guide rebuilds on return from a tune.
struct LiveTVView: View {
    @EnvironmentObject var session: Session
    @Environment(\.scenePhase) private var scenePhase
    @State var region = UserDefaults.standard.string(forKey: "liveRegion") ?? ""
    @State var chip = UserDefaults.standard.string(forKey: "liveChip") ?? "Guide"
    @State var day = 0
    @State var guide = LiveGuide()
    @State var sports: [LiveSport] = []
    @State var catalog: [Meta] = []            // Local / 24/7 / All Channels / search
    @State var q = ""
    @State var searchTask: Task<Void, Never>?
    @State var locked = false
    @State var loading = true
    @State var builtAt = 0
    @State var now = LiveTV.nowMs()
    @State var favDirty = false
    @State var tune: Meta?
    @State var gamesTask: Task<Void, Never>?

    var searching: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }
    var chips: [String] {
        ["Guide", "★ Favorites"] + guide.sections + (region.isEmpty ? ["Local", "24/7"] : []) + ["All Channels"]
    }
    var catalogChip: Bool { ["Local", "24/7", "All Channels"].contains(chip) }

    #if os(tvOS)
    @Namespace var liveNS
    #endif

    var body: some View {
        platformPage
            .ckFullScreenCover(item: $tune, onDismiss: { Task { await afterTune() } }) { c in LiveTuneView(channel: c) }
            .task(id: "\(session.catalogs.count)|\(session.currentProfile)") { await build(force: false) }
            .onChange(of: scenePhase) { ph in
                // rebuild any Live TV page older than 60s on foreground resume
                if ph == .active, LiveTV.nowMs() - builtAt > 60_000 { Task { await build(force: false) } }
            }
            .onChange(of: q) { v in
                searchTask?.cancel()
                if v.trimmingCharacters(in: .whitespaces).isEmpty { catalog = []; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await runSearch()
                }
            }
            .onAppear { startGamesLoop() }
            .onDisappear { gamesTask?.cancel(); gamesTask = nil }
    }

    /// Apple TV = the Firestick page (TV/LiveTV+TV.swift), Mac = the desktop page
    /// (Mac/LiveTV+Desk.swift), iPhone = the phone page below.
    @ViewBuilder var platformPage: some View {
        #if os(tvOS)
        tvPage
        #elseif os(macOS)
        deskPage
        #else
        phonePage
        #endif
    }

    #if os(iOS)
    var phonePage: some View {
        NavigationStack {
            GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    if locked {
                        lockedPanel
                    } else {
                        if !searching { gamesBanner }
                        if !searching { chipsRow }
                        if searching { searchResults }
                        else if chip == "Guide" {
                            GuideGrid(guide: guide, day: $day, now: now,
                                      onTune: { tuneChannel($0) },
                                      onFav: { toggleFav($0) })
                        }
                        else if chip == "★ Favorites" { channelList(guide.favChannels, empty: "Long-press a channel to add it here.") }
                        else if catalogChip { catalogList }
                        else { channelList(guide.channels.filter { $0.section == chip }, empty: "Nothing in this section right now.") }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                    }
                }
                .padding(.vertical, 8)
                .frame(width: geo.size.width, alignment: .leading)
                .environment(\.ckGuideWidth, geo.size.width)
            }
            }
            .background(Theme.bg)
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .ckTrailing) {
                    Menu {
                        ForEach(LiveTV.regions, id: \.0) { code, label in
                            Button(code == region ? "✓ " + label : label) { setRegion(code) }
                        }
                    } label: {
                        Text((LiveTV.regions.first { $0.0 == region }?.1 ?? "🌎 USA") + " ▾").font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.card, in: Capsule())
                    }
                }
            }
            .searchable(text: $q, prompt: "Channels & shows airing soon")
            .onSubmit(of: .search) { searchTask?.cancel(); Task { await runSearch() } }
        }
    }
    #endif

    /// Region-aware games (web/Firestick keep()): Fútbol rides with the UK view; USA / UK / CA
    /// each see the games on their own channels — live strips and upcoming both.
    var regionSports: [LiveSport] {
        let want = region.isEmpty ? "US" : region
        return sports.compactMap { sp in
            let keep: (LiveGame) -> Bool = { g in sp.sport == "Fútbol" ? want == "UK" : g.rg == want }
            let l = sp.live.filter(keep), so = sp.soon.filter(keep)
            return l.isEmpty && so.isEmpty ? nil : LiveSport(sport: sp.sport, emoji: sp.emoji, live: l, soon: so)
        }
    }

    // MARK: pieces

    var lockedPanel: some View {
        VStack(spacing: 10) {
            Text("🔒").font(.system(size: 48))
            Text("CouchKing Live TV — Locked").font(.system(size: 22, weight: .bold))
            Text("Live TV isn't part of your plan.\nContact support to unlock it.")
                .font(.system(size: 14)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    /// Per-sport red "LIVE NOW" strips + one "📅 Upcoming games" strip (games.json).
    @ViewBuilder var gamesBanner: some View {
        // REGION-FILTERED (the raw list leaked Fútbol/Europe into the US view AND its flood
        // pushed real US games past the cap — AJ "upcoming games have europe games… we are
        // missing games"). regionSports = the same keep() rule web/Firestick apply.
        let live = regionSports.filter { !$0.live.isEmpty }
        let soon = regionSports.flatMap(\.soon).sorted { $0.s < $1.s }
        if !live.isEmpty || !soon.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(live) { sp in
                    gameStrip(title: "LIVE NOW · \(sp.emoji) \(sp.sport)", games: sp.live, live: true)
                }
                if !soon.isEmpty { gameStrip(title: "📅 Upcoming games", games: Array(soon.prefix(40)), live: false) }
            }
        }
    }

    func gameStrip(title: String, games: [LiveGame], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(live ? Color.red : Theme.panel, in: Capsule())
                .foregroundStyle(.white)
                .padding(.horizontal, Platform.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Platform.isTV ? 40 : 8) {
                    ForEach(games) { g in
                        Button { tune = g.meta } label: {
                            HStack(spacing: 8) {
                                AsyncImage(url: URL(string: g.logo)) { img in
                                    img.resizable().aspectRatio(contentMode: .fit)
                                } placeholder: { Image(systemName: "sportscourt").foregroundStyle(.secondary) }
                                .frame(width: 36, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.t).font(.caption.bold()).lineLimit(1)
                                    // WHEN leads and is bright — long channel names were eating
                                    // the kickoff time ("can't see when they're playing")
                                    if live {
                                        Text(g.ch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    } else {
                                        HStack(spacing: 4) {
                                            Text(g.when).font(.caption2.bold()).foregroundStyle(Theme.gold)
                                            Text("· " + g.ch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                            .padding(8).frame(width: 210, alignment: .leading)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(live ? Color.red.opacity(0.7) : .clear, lineWidth: 1))
                        }
                        .ckTile()
                    }
                }
                .padding(.horizontal, Platform.gutter)
                .padding(.vertical, Platform.isTV ? 36 : 0)   // room for the focus lift
            }
            .ckFocusSection()
        }
    }

    var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { c in
                    Button(c) { setChip(c) }
                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(chip == c ? Theme.accent : Theme.card, in: Capsule())
                        .foregroundStyle(chip == c ? .white : .primary)
                }
            }
            .padding(.horizontal, Platform.gutter)
            .padding(.vertical, Platform.isTV ? 36 : 0)   // room for the focus lift
        }
        .ckFocusSection()
    }

    @ViewBuilder func channelList(_ list: [LiveChannel], empty: String) -> some View {
        if list.isEmpty && !loading {
            Text(empty).foregroundStyle(.secondary).padding(24)
        }
        ForEach(list) { ch in
            ChannelRow(name: ch.name, logo: ch.logo, now: ch.now(now)?.t ?? "",
                       next: ch.next(now).map { "Next: \($0.t) · \(LiveTV.clock($0.s))" } ?? "",
                       fav: guide.favs.contains(ch.id))
                .liveTap({ tuneChannel(ch) }, fav: { toggleFav(ch) }, isFav: guide.favs.contains(ch.id))
                .padding(.horizontal, Platform.gutter)
        }
    }

    @ViewBuilder var catalogList: some View {
        if catalog.isEmpty && !loading {
            Text("Nothing here right now.").foregroundStyle(.secondary).padding(24)
        }
        ForEach(catalog) { m in
            ChannelRow(name: m.name, logo: m.poster ?? m.logo ?? "", now: m.description ?? "", next: "",
                       fav: guide.favs.contains(m.id.replacingOccurrences(of: "cklive:", with: "")))
                .liveTap({ tune = m },
                         fav: { toggleFavId(m.id.replacingOccurrences(of: "cklive:", with: ""), channel: nil) },
                         isFav: guide.favs.contains(m.id.replacingOccurrences(of: "cklive:", with: "")))
                .padding(.horizontal, Platform.gutter)
        }
    }

    @ViewBuilder var searchResults: some View {
        if catalog.isEmpty && !loading {
            Text("No channels or shows match.").foregroundStyle(.secondary).padding(24)
        }
        ForEach(catalog) { m in
            ChannelRow(name: m.name, logo: m.poster ?? m.logo ?? "", now: m.description ?? "", next: "", fav: false)
                .liveTap({ tune = m })
                .padding(.horizontal, Platform.gutter)
        }
    }

    // MARK: actions

    func setRegion(_ code: String) {
        region = code
        UserDefaults.standard.set(code, forKey: "liveRegion")
        setChip("Guide")
        Task { await build(force: true) }
    }

    func setChip(_ c: String) {
        chip = c
        UserDefaults.standard.set(c, forKey: "liveChip")
        if catalogChip { Task { await loadCatalog() } }
    }

    func tuneChannel(_ ch: LiveChannel) { tune = ch.meta(now) }

    func toggleFav(_ ch: LiveChannel) { toggleFavId(ch.id, channel: ch) }

    /// Long-press ★ toggle: patch locally so the star shows instantly, then POST the desired state.
    func toggleFavId(_ id: String, channel: LiveChannel?) {
        let on = !guide.favs.contains(id)
        let ch = channel ?? guide.channels.first { $0.id == id }
        guide.favs.removeAll { $0 == id }
        guide.favChannels.removeAll { $0.id == id }
        if on { guide.favs.append(id); if let ch { guide.favChannels.append(ch) } }
        LiveTV.patchFav(region: region, id: id, on: on, channel: ch)
        favDirty = true
        Task { _ = await LiveTV.setFav(session, id: id, on: on) }
    }

    /// Build the page (Android liveRenderGuide): guide + games, stamped for the 60s staleness rule.
    func build(force: Bool) async {
        guard session.catalogs.contains(where: { $0.isLive }) else { loading = false; return }
        loading = true
        now = LiveTV.nowMs()
        switch await LiveTV.guide(session, region: region, force: force) {
        case .ok(let g): guide = g; locked = false
            if g.at > 0 { now = g.at }
        case .locked: locked = true
        case .failed: break
        }
        if !locked && guide.channels.isEmpty {
            // no guide but a catalog: the catalog's single cklive:upgrade meta = locked plan
            let list = await LiveTV.catalog(session)
            if list.count == 1 && list[0].id == "cklive:upgrade" { locked = true }
        }
        sports = await LiveTV.games(session)
        if catalogChip { await loadCatalog() }
        builtAt = LiveTV.nowMs()
        loading = false
    }

    /// Back from the player: freeze-and-rebuild the guide centered on NOW; refetch favs +
    /// recent when the in-player ★ / channel-hop set the dirty flag.
    func afterTune() async {
        now = LiveTV.nowMs()
        let force = favDirty
        favDirty = false
        await build(force: force)
    }

    func loadCatalog() async {
        loading = true
        catalog = await LiveTV.catalog(session, genre: chip == "All Channels" ? "" : chip)
        loading = false
    }

    func runSearch() async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let r = await LiveTV.catalog(session, search: query)
        if q.trimmingCharacters(in: .whitespaces) == query { catalog = r }   // ignore stale response
    }

    /// The games banner self-refreshes every 3 minutes (never served stale).
    func startGamesLoop() {
        gamesTask?.cancel()
        gamesTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                sports = await LiveTV.games(session)
                now = LiveTV.nowMs()
            }
        }
    }
}

/// Channel row (Android liveRow): logo, name, ★, LIVE badge, now-playing + next line.
struct ChannelRow: View {
    let name: String, logo: String, now: String, next: String, fav: Bool
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: logo)) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
            .frame(width: 64, height: 40)
            .padding(6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if fav { Text("★").font(.caption).foregroundStyle(.yellow) }
                    Text(name).font(.subheadline.bold()).lineLimit(1)
                    Text("LIVE").font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                }
                if !now.isEmpty { Text(now).font(.caption).lineLimit(1) }
                if !next.isEmpty { Text(next).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

// MARK: - guide grid

/// The guide grid (Android liveRenderGuide): day tabs, ↻ recent strip, ★ favorites first then
/// SECTION headers, a fixed channel column + a shared horizontal timeline (4px/min) with the
/// current programme highlighted and a 2px red now-line. Rows are lazy; the timeline pans with
/// one shared offset so every row and the pinned tick header stay aligned.
/// The Live page's exact viewport width — the guide sizes its timeline off this so the
/// channel column can never be pushed off-screen by the (72h-wide) virtual timeline.
private struct CKGuideWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 393 }
extension EnvironmentValues {
    var ckGuideWidth: CGFloat {
        get { self[CKGuideWidthKey.self] }
        set { self[CKGuideWidthKey.self] = newValue }
    }
}

struct GuideGrid: View {
    let guide: LiveGuide
    @Binding var day: Int
    let now: Int
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void
    @State private var scrollX: CGFloat = 0
    @State private var dragStart: CGFloat? = nil
    @Environment(\.ckGuideWidth) private var pageW
    /// The visible timeline strip: page − gutter − channel column. EVERY row and the tick
    /// header clip to exactly this, so the 17,000pt virtual timeline can't shove the
    /// channel column off-screen (AJ: "can't see the channels on the left").
    private var timelineW: CGFloat { max(120, pageW - Platform.gutter - Self.colW) }

    // 10-foot TV needs bigger blocks; the desktop sits in between (Firestick / Electron guide).
    static let pxPerMin: CGFloat = Platform.isTV ? 10 : (Platform.isMac ? 6 : 4)
    static let colW: CGFloat = Platform.isTV ? 200 : (Platform.isMac ? 140 : 96)
    static let rowH: CGFloat = Platform.isTV ? 90 : (Platform.isMac ? 60 : 56)
    /// Apple TV timeline width (1920pt screen − safe-area gutters − channel column). Blocks are
    /// laid out inside this fixed width so focus frames stay exact.
    static let tvTimelineW: CGFloat = 1920 - 2 * 60 - 200

    private var dayStart: Int { LiveTV.dayStart(day, now: now) }
    private var windowMs: Int { (day == 0 ? 72 : 24) * 3_600_000 }
    private var windowW: CGFloat { CGFloat(windowMs / 60_000) * Self.pxPerMin }

    enum Line: Identifiable {
        case header(String), channel(LiveChannel)
        var id: String {
            switch self { case .header(let t): return "h:" + t; case .channel(let c): return "c:" + c.id }
        }
    }
    private var lines: [Line] {
        var out: [Line] = []
        let favs = Set(guide.favs)
        let favList = guide.channels.filter { favs.contains($0.id) }
        if !favList.isEmpty { out.append(.header("★ FAVORITES")); out += favList.map { .channel($0) } }
        var bySection: [String: [LiveChannel]] = [:]
        var order: [String] = []
        for c in guide.channels where !favs.contains(c.id) {
            if bySection[c.section] == nil { order.append(c.section) }
            bySection[c.section, default: []].append(c)
        }
        for s in order {
            if !s.isEmpty { out.append(.header(s.uppercased())) }
            out += (bySection[s] ?? []).map { .channel($0) }
        }
        return out
    }
    private var recent: [LiveChannel] {
        guide.recent.compactMap { id in (guide.channels + guide.favChannels).first { $0.id == id } }
    }

    var body: some View {
        // day tabs (session-only, always opens on Today)
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { d in
                Button(LiveTV.dayLabel(d, now: now)) { day = d; scrollX = 0 }
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(day == d ? Theme.panel : .clear, in: Capsule())
                    .overlay(Capsule().stroke(day == d ? Theme.accent : Theme.card, lineWidth: 1))
                    .foregroundStyle(.primary)
            }
            #if os(macOS)
            Spacer()
            Button { shift(-1) } label: { Label("Earlier", systemImage: "chevron.left") }
            Button { shift(1) } label: { Label("Later", systemImage: "chevron.right") }
            #endif
        }
        .padding(.horizontal, Platform.gutter)
        if !recent.isEmpty && day == 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("↻ Continue watching").font(.caption.bold()).padding(.horizontal, Platform.gutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Platform.isTV ? 40 : 8) {
                        ForEach(recent) { ch in
                            Button { onTune(ch) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ch.name).font(.caption.bold()).lineLimit(1)
                                    Text(ch.now(now)?.t ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(8).frame(width: 150, alignment: .leading)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .ckTile()
                        }
                    }
                    .padding(.horizontal, Platform.gutter)
                    .padding(.vertical, Platform.isTV ? 36 : 0)   // room for the focus lift
                }
                .ckFocusSection()
            }
        }
        if guide.channels.isEmpty {
            Text("No guide right now — pull to refresh.").foregroundStyle(.secondary).padding(24)
        }
        Section(header: tickHeader.background(Theme.bg)) {
            LazyVStack(spacing: 2) {
                ForEach(lines) { line in
                    switch line {
                    case .header(let t):
                        Text(t).font(.caption.bold()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Platform.gutter).padding(.top, 8)
                    case .channel(let ch):
                        GuideRow(channel: ch, dayStart: dayStart, windowW: windowW, now: now, scrollX: scrollX,
                                 isFav: guide.favs.contains(ch.id),
                                 onTune: { onTune(ch) }, onFav: { onFav(ch) },
                                 onFocusX: { x in scrollX = min(max(0, x - 120), max(0, windowW - timelineW)) },
                                 timelineW: timelineW)
                    }
                }
            }
        }
        #if !os(tvOS)
        // horizontal pan of the shared timeline; vertical drags still scroll the page
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { g in
                    if dragStart == nil {
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        dragStart = scrollX
                    }
                    guard let d = dragStart else { return }
                    scrollX = min(max(0, d - g.translation.width), max(0, windowW - timelineW))
                }
                .onEnded { g in
                    // fling: glide to where the gesture was headed (bare drags felt janky)
                    guard let d = dragStart else { return }
                    let target = min(max(0, d - g.predictedEndTranslation.width), max(0, windowW - timelineW))
                    dragStart = nil
                    withAnimation(.easeOut(duration: 0.5)) { scrollX = target }
                }
        )
        #endif
    }

    /// Mac: step the shared timeline by an hour (the desktop guide's ◀ ▶).
    private func shift(_ hours: CGFloat) {
        scrollX = min(max(0, scrollX + hours * 60 * Self.pxPerMin), max(0, windowW - 260))
    }

    /// Pinned header: date + scroll-synced half-hour ticks + the now-line.
    private var tickHeader: some View {
        HStack(spacing: 0) {
            Text(LiveTV.day(dayStart, "EEE MMM d")).font(.caption2.bold())
                .frame(width: Self.colW, height: 26, alignment: .leading).padding(.leading, 14)
            ZStack(alignment: .topLeading) {
                // only the ticks inside the visible strip — offscreen ones aren't laid out
                ForEach(0..<(windowMs / 1_800_000), id: \.self) { i in
                    let x = CGFloat(i * 30) * Self.pxPerMin - scrollX
                    if x > -80 && x < timelineW {
                        Text(LiveTV.clock(dayStart + i * 1_800_000)).font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .offset(x: x)
                    }
                }
                if now >= dayStart && now < dayStart + windowMs {
                    let x = CGFloat((now - dayStart) / 60_000) * Self.pxPerMin - scrollX
                    if x >= 0 && x < timelineW {
                        Rectangle().fill(.red).frame(width: 2, height: 26).offset(x: x)
                    }
                }
            }
            .frame(width: timelineW, height: 26, alignment: .leading).clipped()
        }
        .padding(.leading, Platform.gutter)
        .background(Theme.bg)
    }
}

/// One guide row: fixed channel cell + that channel's programme blocks on the shared timeline.
struct GuideRow: View {
    let channel: LiveChannel
    let dayStart: Int
    let windowW: CGFloat
    let now: Int
    let scrollX: CGFloat
    var isFav = false
    let onTune: () -> Void
    let onFav: () -> Void
    var onFocusX: ((CGFloat) -> Void)? = nil
    var timelineW: CGFloat = 300

    private var dayEnd: Int { dayStart + Int(windowW / GuideGrid.pxPerMin) * 60_000 }
    private var progs: [LiveProg] { channel.progs.filter { $0.e > dayStart && $0.s < dayEnd } }
    private func x(_ ms: Int) -> CGFloat { CGFloat((ms - dayStart) / 60_000) * GuideGrid.pxPerMin }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                AsyncImage(url: URL(string: channel.logo)) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
                .frame(width: GuideGrid.colW * 0.58, height: GuideGrid.rowH * 0.5)
                Text(channel.name).font(.system(size: Platform.isTV ? 16 : 10, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                    .padding(.horizontal, 2)
            }
            .frame(width: GuideGrid.colW, height: GuideGrid.rowH)
            .background(Theme.panel)
            .contentShape(Rectangle())
            .liveTap(onTune, fav: onFav, isFav: isFav)
            timeline
        }
        .padding(.leading, Platform.gutter)
    }

    #if os(tvOS)
    /// Apple TV: every visible programme is a focusable block laid out (not offset) inside a
    /// fixed-width timeline; focusing one scrolls the shared timeline to it (Firestick guide).
    private var timeline: some View {
        let right = scrollX + GuideGrid.tvTimelineW
        return ZStack(alignment: .leading) {
            ForEach(progs.filter { x($0.e) > scrollX && x($0.s) < right }, id: \.self) { p in
                let vx0 = max(x(p.s), scrollX)
                let vx1 = min(x(p.e), right)
                GuideBlock(prog: p, live: p.s <= now && now < p.e, width: max(8, vx1 - vx0 - 4),
                           onTune: onTune, onFav: onFav, isFav: isFav,
                           onFocus: { onFocusX?(x(p.s)) })
                    .padding(.leading, vx0 - scrollX)
            }
            if now >= dayStart && now < dayEnd, x(now) >= scrollX, x(now) < right {
                Rectangle().fill(.red).frame(width: 3, height: GuideGrid.rowH)
                    .padding(.leading, x(now) - scrollX)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: GuideGrid.tvTimelineW, height: GuideGrid.rowH, alignment: .leading)
        .clipped()
    }
    #else
    private var timeline: some View {
        // Only the blocks that INTERSECT the visible strip are laid out (72h × every channel
        // of offscreen Texts was the scroll jank), each clamped to the strip and clipped —
        // an over-wide block can never push the row past the screen.
        let right = scrollX + timelineW
        return ZStack(alignment: .leading) {
            // blocks keep their FULL width and just slide — clamping them to the visible
            // strip made every title reflow as the box resized while panning (AJ:
            // "disorienting, the words moving to fit"). Offscreen blocks still skipped.
            ForEach(progs.filter { x($0.e) > scrollX && x($0.s) < right }, id: \.self) { p in
                let x0 = x(p.s)
                let live = p.s <= now && now < p.e
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.t).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Text(LiveTV.clock(p.s)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .frame(width: max(8, x(p.e) - x0 - 2), height: GuideGrid.rowH - 6, alignment: .leading)
                .background(live ? Theme.accent.opacity(0.55) : Theme.card,
                            in: RoundedRectangle(cornerRadius: 6))
                .clipped()
                .offset(x: x0 - scrollX)
                .liveTap(onTune, fav: onFav, isFav: isFav)
            }
            if now >= dayStart && now < dayEnd {
                let nx = x(now) - scrollX
                if nx >= 0 && nx < timelineW {
                    Rectangle().fill(.red).frame(width: 2, height: GuideGrid.rowH)
                        .offset(x: nx)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: timelineW, height: GuideGrid.rowH, alignment: .leading).clipped()
    }
    #endif
}

#if os(tvOS)
/// A focusable guide programme: highlighted while live, lifts on focus, reports focus so the
/// shared timeline follows the remote.
struct GuideBlock: View {
    let prog: LiveProg
    let live: Bool
    let width: CGFloat
    let onTune: () -> Void
    let onFav: () -> Void
    let isFav: Bool
    let onFocus: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: onTune) {
            VStack(alignment: .leading, spacing: 2) {
                Text(prog.t).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Text(LiveTV.clock(prog.s) + " – " + LiveTV.clock(prog.e))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: GuideGrid.rowH - 8, alignment: .leading)
            .background(focused ? Theme.accent : (live ? Theme.accent.opacity(0.45) : Theme.card),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .contextMenu {
            Button(isFav ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: isFav ? "star.slash" : "star") { onFav() }
        }
        .onChange(of: focused) { f in if f { onFocus() } }
    }
}
#endif

/// Places each child at its `LaneX` offset (negative = partly off the left edge) inside a
/// fixed-size lane — layout-based, so Apple TV focus frames match what is drawn.
struct LaneX: LayoutValueKey { static let defaultValue: CGFloat = 0 }
struct LaneLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews {
            v.place(at: CGPoint(x: bounds.minX + v[LaneX.self], y: bounds.minY), proposal: .unspecified)
        }
    }
}

extension View {
    /// iPhone: tap = tune, long-press = ★ toggle (Android). Apple TV / Mac: a focusable, clickable
    /// button; ★ lives in the context menu (remote long-press on select / right-click).
    @ViewBuilder func liveTap(_ tune: @escaping () -> Void, fav: (() -> Void)? = nil, isFav: Bool = false) -> some View {
        #if os(iOS)
        // NEVER .onLongPressGesture here: it claims the touch and kills the ScrollView's
        // vertical pan over every guide block (AJ: "can't scroll up and down, only from the
        // top"). A simultaneous long press coexists with scrolling — a real scroll cancels it.
        if let fav {
            self.onTapGesture(perform: tune)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in fav() })
        }
        else { self.onTapGesture(perform: tune) }
        #else
        Button(action: tune) { self }
            .buttonStyle(.plain)
            .contextMenu {
                if let fav {
                    Button(isFav ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: isFav ? "star.slash" : "star") { fav() }
                }
            }
        #endif
    }
}
