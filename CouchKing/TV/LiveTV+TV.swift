#if os(tvOS)
import SwiftUI

// The Firestick Live TV page (reference/android-tv MainActivity.kt buildLiveTv ~1709,
// buildLiveTvBody ~1758, liveRenderBanner ~1949, liveRenderGuide ~2020, liveRow ~2453), 1dp = 2pt.
// No board: "Live TV" 22sp + the "🌎 USA ▾" region chip in the corner · LIVE NOW / Upcoming
// game strips (region-aware) · "🔎 Channels & shows" search · category chips (Guide gets the
// initial focus) · body: the classic guide (day tabs, ↻ Continue watching strip, pinned
// date/ticks header, 150dp channel column, 52dp rows, 4dp per minute, purple current block with
// the red now-line) or channel rows (logo · ★ name · now + red progress · Next).
extension LiveTVView {
    var tvPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if locked {
                    tvLocked
                } else {
                    tvHead
                    tvBanner
                    tvSearch
                    tvChips
                    tvBody
                }
            }
            .padding(.leading, TV.dp(64 + 12)).padding(.trailing, TV.dp(12))
            .padding(.top, TV.dp(36)).padding(.bottom, TV.dp(30))
        }
        .background(TV.bg.ignoresSafeArea())
        .ignoresSafeArea()
        .focusScope(liveNS)
    }

    private var tvLocked: some View {
        VStack(spacing: 0) {
            Text("🔒").font(.system(size: TV.sp(48)))
            Text("CouchKing Live TV — Locked").font(.system(size: TV.sp(22), weight: .bold)).foregroundStyle(.white)
                .padding(.top, TV.dp(14)).padding(.bottom, TV.dp(8))
            Text("Live TV isn't part of your plan.\nContact support to unlock it.")
                .font(.system(size: TV.sp(14))).foregroundStyle(TV.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 1080 - TV.dp(80))
    }

    // MARK: head — "Live TV" + region chip (the d-pad UP target)

    private var tvHead: some View {
        HStack {
            Text("Live TV").font(.system(size: TV.sp(22), weight: .bold)).foregroundStyle(.white)
            Spacer()
            Menu {
                ForEach(TVLive.regions, id: \.0) { code, label, _ in
                    Button((region == code ? "✓ " : "   ") + label) { setRegion(code) }
                }
            } label: {
                Text("🌎 \(TVLive.regions.first { $0.0 == region }?.2 ?? "USA") ▾")
                    .font(.system(size: TV.sp(12.5))).foregroundStyle(.white)
                    .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(6))
                    .background(TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(18)))
            }
            .buttonStyle(TVRingButton(radius: TV.dp(18)))
        }
    }

    // MARK: games banner

    @ViewBuilder private var tvBanner: some View {
        let sports = regionSports
        let soon = Array(sports.flatMap { sp in sp.soon.map { EmojiGame(emoji: sp.emoji, game: $0) } }
            .sorted { $0.game.s < $1.game.s }.prefix(25))
        ForEach(sports.filter { !$0.live.isEmpty }) { sp in
            Text("\(sp.emoji) \(sp.sport) — LIVE NOW").font(.system(size: TV.sp(13.5))).foregroundStyle(TVLive.red)
                .padding(.top, TV.dp(10)).padding(.bottom, TV.dp(4))
            TVStrip {
                ForEach(sp.live) { g in
                    TVGameCard(title: g.t, sub: "🔴 LIVE • \(g.ch)", live: true) { tune = g.meta }
                }
            }
        }
        if !soon.isEmpty {
            Text("📅 Upcoming games").font(.system(size: TV.sp(13.5))).foregroundStyle(TV.dim)
                .padding(.top, TV.dp(10)).padding(.bottom, TV.dp(4))
            TVStrip {
                ForEach(soon) { eg in
                    TVGameCard(title: eg.emoji + " " + eg.game.t, sub: "\(eg.game.when) • \(eg.game.ch)", live: false) {
                        tune = eg.game.meta
                    }
                }
            }
        }
    }

    // MARK: search + chips

    private var tvSearch: some View {
        TextField("🔎 Channels & shows", text: $q)
            .font(.system(size: TV.sp(13)))
            .padding(.horizontal, TV.dp(14)).padding(.vertical, TV.dp(7))
            .background(TVLive.searchBg, in: RoundedRectangle(cornerRadius: TV.dp(18)))
            .padding(.top, TV.dp(6))
    }

    private var tvChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TV.dp(8)) {
                ForEach(chips, id: \.self) { c in
                    let on = c == chip
                    Button { q = ""; setChip(c) } label: {
                        Text(c).font(.system(size: TV.sp(13.5))).foregroundStyle(on ? .white : TV.dim)
                            .padding(.horizontal, TV.dp(14)).padding(.vertical, TV.dp(7))
                            .background(on ? TV.accent : TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(20)))
                    }
                    .buttonStyle(TVRingButton(radius: TV.dp(20)))
                    .prefersDefaultFocus(c == "Guide", in: liveNS)   // open with the cursor on GUIDE
                }
            }
            .padding(.vertical, TV.dp(8)).padding(.horizontal, TV.dp(4))
        }
        .focusSection()
    }

    // MARK: body

    @ViewBuilder private var tvBody: some View {
        if searching {
            if catalog.isEmpty { TVLive.dimText(loading ? "Loading…" : "No channels or shows match.") }
            ForEach(catalog) { m in tvMetaRow(m) }
        } else if chip == "Guide" {
            if guide.channels.isEmpty { TVLive.dimText("Loading the guide…") }
            else {
                TVGuide(guide: guide, day: $day, now: now, onTune: { tuneChannel($0) }, onFav: { toggleFav($0) })
            }
        } else if chip == "★ Favorites" {
            if guide.favChannels.isEmpty {
                TVLive.dimText("No favorites yet — long-press any channel to ★ it (search finds the hidden ones).")
            }
            ForEach(guide.favChannels) { ch in tvChannelRow(ch) }
        } else if catalogChip {
            if catalog.isEmpty { TVLive.dimText(loading ? "Loading channels…" : "No channels in this category right now.") }
            ForEach(catalog) { m in tvMetaRow(m) }
        } else {
            let list = guide.channels.filter { $0.section == chip }
            if list.isEmpty { TVLive.dimText("Nothing here right now.") }
            ForEach(list) { ch in tvChannelRow(ch) }
        }
    }

    private func tvChannelRow(_ ch: LiveChannel) -> some View {
        let n = ch.now(now), nx = ch.next(now)
        return TVLiveRow(name: ch.name, logo: ch.logo, nowT: n?.t ?? "", nowS: n?.s ?? 0, nowE: n?.e ?? 0,
                         next: nx.map { "Next: \($0.t) • \(LiveTV.clock($0.s))" } ?? "", at: now,
                         fav: guide.favs.contains(ch.id), onFav: { toggleFav(ch) }, onTune: { tuneChannel(ch) })
    }

    private func tvMetaRow(_ m: Meta) -> some View {
        let id = m.id.replacingOccurrences(of: "cklive:", with: "")
        let line = (m.description ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return TVLiveRow(name: m.name, logo: m.poster ?? m.logo ?? "", nowT: line, nowS: 0, nowE: 0, next: "", at: now,
                         fav: guide.favs.contains(id), onFav: { toggleFavId(id, channel: nil) }, onTune: { tune = m })
    }
}

enum TVLive {
    static let regions: [(String, String, String)] = [("", "🇺🇸 USA", "USA"), ("UK", "🇬🇧 UK", "UK"), ("CA", "🇨🇦 Canada", "Canada")]
    static let red = TV.rgb(0xE64545)
    static let searchBg = TV.rgb(0x1C1832)
    static let cell = TV.rgb(0x16132A)
    static let secBg = TV.rgb(0x1B1636), secFg = TV.rgb(0xA08EF0)
    static let blockOn = TV.rgb(0x33285F)
    static let blockTime = TV.rgb(0x9A8FE8)
    static let nowLine = TV.rgb(0xE94B6A)
    static let tabOn = TV.rgb(0x3A3450)

    static func dimText(_ t: String) -> some View {
        Text(t).font(.system(size: TV.sp(13))).foregroundStyle(TV.dim).padding(.vertical, TV.dp(10))
    }
}

/// Every interactive strip is its own horizontal scroller + focus section (the d-pad walks
/// between strips).
struct TVStrip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TV.dp(8)) { content }
                .padding(.vertical, TV.dp(4)).padding(.horizontal, TV.dp(4))
        }
        .focusSection()
    }
}

/// liveGameCard: #2A1A22 (live) / #1C1832, r12, title 13sp (max 260dp), "🔴 LIVE • ch" in red.
struct TVGameCard: View {
    let title: String, sub: String
    let live: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: TV.dp(2)) {
                Text(title).font(.system(size: TV.sp(13))).foregroundStyle(.white).lineLimit(1)
                    .frame(maxWidth: TV.dp(260), alignment: .leading)
                Text(sub).font(.system(size: TV.sp(11))).foregroundStyle(live ? TVLive.red : TV.dim).lineLimit(1)
            }
            .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(8))
            .background(live ? TV.rgb(0x2A1A22) : TVLive.searchBg, in: RoundedRectangle(cornerRadius: TV.dp(12)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(12)))
    }
}

/// liveRow: #1C1832 r12 — 56×38dp logo · gold ★ + name 13.5sp · now 11.5sp · 3dp red progress ·
/// "Next: …" 10.5sp (max 150dp). Select tunes; long-press = ★.
struct TVLiveRow: View {
    let name: String, logo: String, nowT: String, nowS: Int, nowE: Int, next: String
    let at: Int
    let fav: Bool
    let onFav: () -> Void
    let onTune: () -> Void
    var body: some View {
        let pct = nowE > nowS ? min(1, max(0, Double(at - nowS) / Double(nowE - nowS))) : 0
        return Button(action: onTune) {
            HStack(spacing: 0) {
                AsyncImage(url: URL(string: logo)) { img in img.resizable().aspectRatio(contentMode: .fit) }
                    placeholder: { Color.clear }
                    .frame(width: TV.dp(56), height: TV.dp(38)).padding(.trailing, TV.dp(10))
                VStack(alignment: .leading, spacing: 0) {
                    TVLive.starred(name, fav).font(.system(size: TV.sp(13.5))).foregroundStyle(.white).lineLimit(1)
                    if !nowT.isEmpty {
                        Text(nowT).font(.system(size: TV.sp(11.5))).foregroundStyle(TV.dim).lineLimit(1)
                        if nowE > nowS {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(TV.rgb(0x2A2542))
                                    Rectangle().fill(TV.rgb(0xE63946)).frame(width: g.size.width * pct)
                                }
                            }
                            .frame(height: TV.dp(3)).padding(.top, TV.dp(4)).padding(.trailing, TV.dp(20))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !next.isEmpty {
                    Text(next).font(.system(size: TV.sp(10.5))).foregroundStyle(TV.dim).lineLimit(2)
                        .frame(maxWidth: TV.dp(150), alignment: .leading)
                }
            }
            .padding(.horizontal, TV.dp(10)).padding(.vertical, TV.dp(8))
            .background(TVLive.searchBg, in: RoundedRectangle(cornerRadius: TV.dp(12)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(12)))
        .contextMenu {
            Button(fav ? "Remove from favorites" : "★ Add to favorites") { onFav() }
        }
        .padding(.bottom, TV.dp(6))
    }
}

extension TVLive {
    /// "★ Name" with a gold star when favorited.
    static func starred(_ name: String, _ on: Bool) -> Text {
        on ? Text("★ ").foregroundColor(TV.favGold) + Text(name) : Text(name)
    }
}

/// The classic guide (liveRenderGuide): day tabs · ↻ Continue watching strip · pinned header
/// (150dp date cell "EEE M/d" that follows the scroll + 30-minute ticks) · ★ Favorites then
/// SECTION groups (purple uppercase on #1B1636) · rows = 150dp channel cell (#16132A, logo,
/// ★ name) + ONE shared timeline lane at 4dp/min: #241F3D blocks, the airing one #33285F with
/// the red now-line at the current minute, "Live programming" when a channel has no listings.
/// Focusing a block pans the shared lane so the block is in view (all rows move together).
struct TVGuide: View {
    let guide: LiveGuide
    @Binding var day: Int
    let now: Int
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void
    @State private var scrollX: CGFloat = 0

    static let pxPerMin = TV.dp(4)
    static let rowH = TV.dp(52)
    static let colW = TV.dp(150)
    /// 1920 − rail inset (76dp) − right pad (12dp) − channel column − 2dp gap.
    static let laneW: CGFloat = 1920 - TV.dp(76) - TV.dp(12) - TV.dp(150) - TV.dp(2)

    private var dayStart: Int { LiveTV.dayStart(day, now: now) }
    private var winEnd: Int { dayStart + (day == 0 ? 72 : 24) * 3_600_000 }
    private var timelineW: CGFloat { CGFloat((winEnd - dayStart) / 60_000) * Self.pxPerMin }
    private func x(_ ms: Int) -> CGFloat { CGFloat((ms - dayStart) / 60_000) * Self.pxPerMin }

    enum Line: Identifiable {
        case header(String), channel(LiveChannel)
        var id: String { switch self { case .header(let t): return "h:" + t; case .channel(let c): return "c:" + c.id } }
    }
    private var lines: [Line] {
        let favs = Set(guide.favs)
        var out: [Line] = []
        let favRows = guide.channels.filter { favs.contains($0.id) }
        if !favRows.isEmpty { out.append(.header("★ Favorites")); out += favRows.map { .channel($0) } }
        var last = ""
        for c in guide.channels where !favs.contains(c.id) {
            let sec = !c.section.isEmpty ? c.section : (!c.genre.isEmpty ? c.genre : "More Channels")
            if sec != last { out.append(.header(sec)); last = sec }
            out.append(.channel(c))
        }
        return out
    }
    private var recent: [LiveChannel] {
        Array(guide.recent.compactMap { id in guide.channels.first { $0.id == id } }.prefix(12))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            dayTabs
            if !recent.isEmpty {
                Text("↻ Continue watching").font(.system(size: TV.sp(12.5))).foregroundStyle(TV.dim)
                    .padding(.top, TV.dp(2)).padding(.bottom, TV.dp(4))
                TVStrip {
                    ForEach(recent) { c in
                        let nt = c.now(now)?.t ?? ""
                        Button { onTune(c) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.name).font(.system(size: TV.sp(12.5))).foregroundStyle(.white).lineLimit(1)
                                if !nt.isEmpty {
                                    Text(nt).font(.system(size: TV.sp(10.5))).foregroundStyle(TV.dim).lineLimit(1)
                                        .frame(maxWidth: TV.dp(200), alignment: .leading)
                                }
                            }
                            .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(8))
                            .background(TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(12)))
                        }
                        .buttonStyle(TVRingButton(radius: TV.dp(12)))
                    }
                }
            }
            Section(header: header) {
                ForEach(lines) { line in
                    switch line {
                    case .header(let t): secHeader(t)
                    case .channel(let c): row(c)
                    }
                }
            }
        }
        .onChange(of: day) { _ in scrollX = 0 }
    }

    private var dayTabs: some View {
        TVStrip {
            ForEach(0..<4, id: \.self) { d in
                let on = d == day
                Button { day = d } label: {
                    Text(d < 2 ? LiveTV.dayLabel(d, now: now) : LiveTV.day(now + d * 86_400_000, "EEEE"))
                        .font(.system(size: TV.sp(12.5))).foregroundStyle(on ? .white : TV.dim)
                        .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(5))
                        .background(on ? TVLive.tabOn : TVLive.searchBg, in: RoundedRectangle(cornerRadius: TV.dp(14)))
                }
                .buttonStyle(TVRingButton(radius: TV.dp(14)))
            }
        }
        .padding(.top, TV.dp(4)).padding(.bottom, TV.dp(6))
    }

    /// The pinned header: date cell (follows the scroll across midnight) + scroll-synced ticks.
    private var header: some View {
        HStack(spacing: TV.dp(2)) {
            Text(LiveTV.day(dayStart + Int(scrollX / Self.pxPerMin) * 60_000, "EEE M/d"))
                .font(.system(size: TV.sp(12.5))).foregroundStyle(.white)
                .padding(.leading, TV.dp(6)).padding(.top, TV.dp(4))
                .frame(width: Self.colW, height: TV.dp(26), alignment: .topLeading)
                .background(TVLive.cell, in: RoundedRectangle(cornerRadius: TV.dp(6)))
            LaneLayout {
                ForEach(0..<Int((winEnd - dayStart) / 1_800_000), id: \.self) { i in
                    let tx = CGFloat(i * 30) * Self.pxPerMin
                    if tx + 30 * Self.pxPerMin > scrollX - Self.laneW && tx < scrollX + 2 * Self.laneW {
                        Text(LiveTV.clock(dayStart + i * 1_800_000)).font(.system(size: TV.sp(11.5))).foregroundStyle(.white)
                            .padding(.leading, TV.dp(4)).padding(.top, TV.dp(3))
                            .frame(width: 30 * Self.pxPerMin, height: TV.dp(26), alignment: .topLeading)
                            .layoutValue(key: LaneX.self, value: tx - scrollX)
                    }
                }
            }
            .frame(width: Self.laneW, height: TV.dp(26)).clipped()
        }
        .padding(.vertical, TV.dp(2))
        .background(TV.bg)
    }

    private func secHeader(_ t: String) -> some View {
        HStack(spacing: TV.dp(2)) {
            Text(t.uppercased()).font(.system(size: TV.sp(10.5), weight: .bold)).foregroundStyle(TVLive.secFg)
                .padding(.leading, TV.dp(6)).padding(.top, TV.dp(3))
                .frame(width: Self.colW, height: TV.dp(22), alignment: .topLeading)
                .background(TVLive.secBg)
            TVLive.secBg.frame(width: Self.laneW, height: TV.dp(22))
        }
        .padding(.top, TV.dp(4)).padding(.bottom, TV.dp(1))
    }

    private func row(_ c: LiveChannel) -> some View {
        let fav = guide.favs.contains(c.id)
        let progs = c.progs.filter { $0.e > dayStart && $0.s < winEnd }
        let lo = scrollX - Self.laneW / 2, hi = scrollX + Self.laneW * 1.5
        return HStack(spacing: TV.dp(2)) {
            Button { onTune(c) } label: {
                HStack(spacing: TV.dp(5)) {
                    if !c.logo.isEmpty {
                        AsyncImage(url: URL(string: c.logo)) { img in img.resizable().aspectRatio(contentMode: .fit) }
                            placeholder: { Color.clear }
                            .frame(width: TV.dp(26), height: TV.dp(26))
                    }
                    TVLive.starred(c.name, fav).font(.system(size: TV.sp(12.5))).foregroundStyle(.white).lineLimit(2)
                }
                .padding(.leading, TV.dp(6)).padding(.trailing, TV.dp(4))
                .frame(width: Self.colW, height: Self.rowH, alignment: .leading)
                .background(TVLive.cell, in: RoundedRectangle(cornerRadius: TV.dp(8)))
            }
            .buttonStyle(TVRingButton(radius: TV.dp(8)))
            .contextMenu { Button(fav ? "Remove from favorites" : "★ Add to favorites") { onFav(c) } }
            LaneLayout {
                if progs.isEmpty {
                    TVGuideBlock(title: "Live programming", time: "", current: false, width: TV.dp(360), nowX: nil,
                                 empty: true, onTune: { onTune(c) }, onFav: { onFav(c) }, fav: fav,
                                 onFocus: { focus(0, TV.dp(360)) })
                        .layoutValue(key: LaneX.self, value: -scrollX)
                } else {
                    ForEach(progs, id: \.self) { p in
                        let cs = max(p.s, dayStart), ce = min(p.e, winEnd)
                        let x0 = x(cs), w = max(TV.dp(40), x(ce) - x0)
                        if x0 + w > lo && x0 < hi {
                            let cur = p.s <= now && p.e > now
                            TVGuideBlock(title: p.t, time: LiveTV.clock(p.s), current: cur, width: w - TV.dp(2),
                                         nowX: cur ? min(max(0, x(now) - x0), w - TV.dp(5)) : nil, empty: false,
                                         onTune: { onTune(c) }, onFav: { onFav(c) }, fav: fav,
                                         onFocus: { focus(x0, x0 + w) })
                                .layoutValue(key: LaneX.self, value: x0 + TV.dp(1) - scrollX)
                        }
                    }
                }
            }
            .frame(width: Self.laneW, height: Self.rowH).clipped()
        }
        .padding(.vertical, TV.dp(1))
    }

    /// Pan the shared lane just enough to show the focused block (with a peek either side so
    /// the neighbours stay reachable), like the Firestick's HorizontalScrollView.
    private func focus(_ x0: CGFloat, _ x1: CGFloat) {
        let peek = TV.dp(30)
        var nx = scrollX
        if x0 < scrollX + peek { nx = x0 - peek }
        else if x1 > scrollX + Self.laneW - peek { nx = min(x0 - peek, x1 - Self.laneW + peek) }
        nx = min(max(0, nx), max(0, timelineW - Self.laneW))
        if nx != scrollX { withAnimation(.easeOut(duration: 0.15)) { scrollX = nx } }
    }
}

/// One focusable programme block: #241F3D r8 (current #33285F + the 2dp red now-line), title
/// 10.5sp (white when airing, dim otherwise) over the start time in #9A8FE8.
struct TVGuideBlock: View {
    let title: String, time: String
    let current: Bool
    let width: CGFloat
    let nowX: CGFloat?
    let empty: Bool
    let onTune: () -> Void
    let onFav: () -> Void
    let fav: Bool
    let onFocus: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: onTune) {
            ZStack(alignment: .topLeading) {
                if empty {
                    Text(title).font(.system(size: TV.sp(10.5))).foregroundStyle(TV.dim)
                        .padding(.horizontal, TV.dp(10))
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: TV.sp(10.5))).foregroundStyle(current ? .white : TV.dim).lineLimit(1)
                        Text(time).font(.system(size: TV.sp(10.5))).foregroundStyle(TVLive.blockTime).lineLimit(1)
                    }
                    .padding(.leading, TV.dp(6)).padding(.trailing, TV.dp(4)).padding(.top, TV.dp(4))
                }
                if let nowX {
                    TVLive.nowLine.frame(width: TV.dp(2)).frame(maxHeight: .infinity).offset(x: nowX)
                }
            }
            .frame(width: max(TV.dp(8), width), height: TVGuide.rowH, alignment: .topLeading)
            .background(empty ? TVLive.cell : (current ? TVLive.blockOn : TV.card2),
                        in: RoundedRectangle(cornerRadius: TV.dp(8)))
            .clipShape(RoundedRectangle(cornerRadius: TV.dp(8)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(8)))
        .focused($focused)
        .contextMenu { Button(fav ? "Remove from favorites" : "★ Add to favorites") { onFav() } }
        .onChange(of: focused) { f in if f { onFocus() } }
    }
}
#endif
