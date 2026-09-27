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
    @State private var region = UserDefaults.standard.string(forKey: "liveRegion") ?? ""
    @State private var chip = UserDefaults.standard.string(forKey: "liveChip") ?? "Guide"
    @State private var day = 0
    @State private var guide = LiveGuide()
    @State private var sports: [LiveSport] = []
    @State private var catalog: [Meta] = []            // Local / 24/7 / All Channels / search
    @State private var q = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var locked = false
    @State private var loading = true
    @State private var builtAt = 0
    @State private var now = LiveTV.nowMs()
    @State private var favDirty = false
    @State private var tune: Meta?
    @State private var gamesTask: Task<Void, Never>?

    private var searching: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }
    private var chips: [String] {
        ["Guide", "★ Favorites"] + guide.sections + (region.isEmpty ? ["Local", "24/7"] : []) + ["All Channels"]
    }
    private var catalogChip: Bool { ["Local", "24/7", "All Channels"].contains(chip) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if locked {
                        lockedPanel
                    } else {
                        if !searching { gamesBanner }
                        if !searching { chipsRow }
                        if searching { searchResults }
                        else if chip == "Guide" { GuideGrid(guide: guide, day: $day, now: now,
                                                            onTune: { tuneChannel($0) },
                                                            onFav: { toggleFav($0) }) }
                        else if chip == "★ Favorites" { channelList(guide.favChannels, empty: "Long-press a channel to add it here.") }
                        else if catalogChip { catalogList }
                        else { channelList(guide.channels.filter { $0.section == chip }, empty: "Nothing in this section right now.") }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.bg)
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
            .onChange(of: q) { v in
                searchTask?.cancel()
                if v.trimmingCharacters(in: .whitespaces).isEmpty { catalog = []; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await runSearch()
                }
            }
            .fullScreenCover(item: $tune, onDismiss: { Task { await afterTune() } }) { c in LiveTuneView(channel: c) }
            .task(id: "\(session.catalogs.count)|\(session.currentProfile)") { await build(force: false) }
            .onChange(of: scenePhase) { ph in
                // rebuild any Live TV page older than 60s on foreground resume
                if ph == .active, LiveTV.nowMs() - builtAt > 60_000 { Task { await build(force: false) } }
            }
            .onAppear { startGamesLoop() }
            .onDisappear { gamesTask?.cancel(); gamesTask = nil }
        }
    }

    // MARK: pieces

    private var lockedPanel: some View {
        VStack(spacing: 10) {
            Text("🔒").font(.system(size: 54))
            Text("Live TV — Locked").font(.title3.bold())
            Text("Live TV isn't part of your plan.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    /// Per-sport red "LIVE NOW" strips + one "📅 Upcoming games" strip (games.json).
    @ViewBuilder private var gamesBanner: some View {
        let live = sports.filter { !$0.live.isEmpty }
        let soon = sports.flatMap(\.soon).sorted { $0.s < $1.s }
        if !live.isEmpty || !soon.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(live) { sp in
                    gameStrip(title: "LIVE NOW · \(sp.emoji) \(sp.sport)", games: sp.live, live: true)
                }
                if !soon.isEmpty { gameStrip(title: "📅 Upcoming games", games: Array(soon.prefix(30)), live: false) }
            }
        }
    }

    private func gameStrip(title: String, games: [LiveGame], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(live ? Color.red : Theme.panel, in: Capsule())
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(games) { g in
                        Button { tune = g.meta } label: {
                            HStack(spacing: 8) {
                                AsyncImage(url: URL(string: g.logo)) { img in
                                    img.resizable().aspectRatio(contentMode: .fit)
                                } placeholder: { Image(systemName: "sportscourt").foregroundStyle(.secondary) }
                                .frame(width: 36, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.t).font(.caption.bold()).lineLimit(1)
                                    Text(live ? g.ch : "\(g.ch) · \(g.when)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(8).frame(width: 210, alignment: .leading)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(live ? Color.red.opacity(0.7) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { c in
                    Button(c) { setChip(c) }
                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(chip == c ? Theme.accent : Theme.card, in: Capsule())
                        .foregroundStyle(chip == c ? .white : .primary)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private func channelList(_ list: [LiveChannel], empty: String) -> some View {
        if list.isEmpty && !loading {
            Text(empty).foregroundStyle(.secondary).padding(24)
        }
        ForEach(list) { ch in
            ChannelRow(name: ch.name, logo: ch.logo, now: ch.now(now)?.t ?? "",
                       next: ch.next(now).map { "Next: \($0.t) · \(LiveTV.clock($0.s))" } ?? "",
                       fav: guide.favs.contains(ch.id))
                .onTapGesture { tuneChannel(ch) }
                .onLongPressGesture { toggleFav(ch) }
                .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private var catalogList: some View {
        if catalog.isEmpty && !loading {
            Text("Nothing here right now.").foregroundStyle(.secondary).padding(24)
        }
        ForEach(catalog) { m in
            ChannelRow(name: m.name, logo: m.poster ?? m.logo ?? "", now: m.description ?? "", next: "",
                       fav: guide.favs.contains(m.id.replacingOccurrences(of: "cklive:", with: "")))
                .onTapGesture { tune = m }
                .onLongPressGesture { toggleFavId(m.id.replacingOccurrences(of: "cklive:", with: ""), channel: nil) }
                .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private var searchResults: some View {
        if catalog.isEmpty && !loading {
            Text("No channels or shows match.").foregroundStyle(.secondary).padding(24)
        }
        ForEach(catalog) { m in
            ChannelRow(name: m.name, logo: m.poster ?? m.logo ?? "", now: m.description ?? "", next: "", fav: false)
                .onTapGesture { tune = m }
                .padding(.horizontal, 14)
        }
    }

    // MARK: actions

    private func setRegion(_ code: String) {
        region = code
        UserDefaults.standard.set(code, forKey: "liveRegion")
        setChip("Guide")
        Task { await build(force: true) }
    }

    private func setChip(_ c: String) {
        chip = c
        UserDefaults.standard.set(c, forKey: "liveChip")
        if catalogChip { Task { await loadCatalog() } }
    }

    private func tuneChannel(_ ch: LiveChannel) { tune = ch.meta(now) }

    private func toggleFav(_ ch: LiveChannel) { toggleFavId(ch.id, channel: ch) }

    /// Long-press ★ toggle: patch locally so the star shows instantly, then POST the desired state.
    private func toggleFavId(_ id: String, channel: LiveChannel?) {
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
    private func build(force: Bool) async {
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
    private func afterTune() async {
        now = LiveTV.nowMs()
        let force = favDirty
        favDirty = false
        await build(force: force)
    }

    private func loadCatalog() async {
        loading = true
        catalog = await LiveTV.catalog(session, genre: chip == "All Channels" ? "" : chip)
        loading = false
    }

    private func runSearch() async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let r = await LiveTV.catalog(session, search: query)
        if q.trimmingCharacters(in: .whitespaces) == query { catalog = r }   // ignore stale response
    }

    /// The games banner self-refreshes every 3 minutes (never served stale).
    private func startGamesLoop() {
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
struct GuideGrid: View {
    let guide: LiveGuide
    @Binding var day: Int
    let now: Int
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void
    @State private var scrollX: CGFloat = 0
    @State private var dragStart: CGFloat? = nil

    static let pxPerMin: CGFloat = 4
    static let colW: CGFloat = 96
    static let rowH: CGFloat = 56

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
        }
        .padding(.horizontal, 14)
        if !recent.isEmpty && day == 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("↻ Continue watching").font(.caption.bold()).padding(.horizontal, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(recent) { ch in
                            Button { onTune(ch) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ch.name).font(.caption.bold()).lineLimit(1)
                                    Text(ch.now(now)?.t ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(8).frame(width: 150, alignment: .leading)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
        if guide.channels.isEmpty {
            Text("No guide right now — pull to refresh.").foregroundStyle(.secondary).padding(24)
        }
        VStack(spacing: 4) {
            tickHeader
            LazyVStack(spacing: 2) {
                ForEach(lines) { line in
                    switch line {
                    case .header(let t):
                        Text(t).font(.caption.bold()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.top, 8)
                    case .channel(let ch):
                        GuideRow(channel: ch, dayStart: dayStart, windowW: windowW, now: now, scrollX: scrollX,
                                 onTune: { onTune(ch) }, onFav: { onFav(ch) })
                    }
                }
            }
        }
        // horizontal pan of the shared timeline; vertical drags still scroll the page
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { g in
                    if dragStart == nil {
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        dragStart = scrollX
                    }
                    scrollX = min(max(0, (dragStart ?? 0) - g.translation.width), max(0, windowW - 260))
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    /// Pinned header: date + scroll-synced half-hour ticks + the now-line.
    private var tickHeader: some View {
        HStack(spacing: 0) {
            Text(LiveTV.day(dayStart, "EEE MMM d")).font(.caption2.bold())
                .frame(width: Self.colW, height: 24, alignment: .leading).padding(.leading, 14)
            ZStack(alignment: .topLeading) {
                ForEach(0..<(windowMs / 1_800_000), id: \.self) { i in
                    Text(LiveTV.clock(dayStart + i * 1_800_000)).font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(i * 30) * Self.pxPerMin - scrollX)
                }
                if now >= dayStart && now < dayStart + windowMs {
                    Rectangle().fill(.red).frame(width: 2, height: 24)
                        .offset(x: CGFloat((now - dayStart) / 60_000) * Self.pxPerMin - scrollX)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24).clipped()
        }
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
    let onTune: () -> Void
    let onFav: () -> Void

    private var dayEnd: Int { dayStart + Int(windowW / GuideGrid.pxPerMin) * 60_000 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                AsyncImage(url: URL(string: channel.logo)) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
                .frame(width: 56, height: 28)
                Text(channel.name).font(.system(size: 9)).lineLimit(1)
            }
            .frame(width: GuideGrid.colW, height: GuideGrid.rowH)
            .background(Theme.panel)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTune)
            .onLongPressGesture(perform: onFav)
            ZStack(alignment: .leading) {
                ForEach(channel.progs.filter { $0.e > dayStart && $0.s < dayEnd }, id: \.self) { p in
                    let x0 = max(0, CGFloat((p.s - dayStart) / 60_000) * GuideGrid.pxPerMin)
                    let x1 = min(windowW, CGFloat((p.e - dayStart) / 60_000) * GuideGrid.pxPerMin)
                    let live = p.s <= now && now < p.e
                    Text(p.t).font(.system(size: 11)).lineLimit(2)
                        .padding(.horizontal, 6)
                        .frame(width: max(8, x1 - x0 - 2), height: GuideGrid.rowH - 6, alignment: .leading)
                        .background(live ? Theme.accent.opacity(0.55) : Theme.card,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: x0 - scrollX)
                        .onTapGesture(perform: onTune)
                }
                if now >= dayStart && now < dayEnd {
                    Rectangle().fill(.red).frame(width: 2, height: GuideGrid.rowH)
                        .offset(x: CGFloat((now - dayStart) / 60_000) * GuideGrid.pxPerMin - scrollX)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: GuideGrid.rowH).clipped()
        }
        .padding(.leading, 14)
    }
}
