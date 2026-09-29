#if os(macOS)
import SwiftUI
import AppKit

// The desktop Live TV page (reference/desktop index.html #view-livetv, app.js livetvPage() /
// lvRenderGuide() / lvRenderBanner() / _lvRow(), style.css 351-460):
// "Live TV" h2 + region <select> in the corner · live-games banner (sport strips only while a
// game is live + one "📅 Upcoming games" strip, region-aware) · .lv-chips (Guide · ★ Favorites ·
// sections · [Local · 24/7] · All Channels) with the "🔎 Channels & shows" search inline · body:
// the classic EPG (day chips, Continue watching strip, bordered grid with a sticky 210px channel
// column + 30px time header, 260px per half hour, 56px rows, red now-line) or .lvg-chrow rows.
extension LiveTVView {
    var deskPage: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    deskHead
                    if locked {
                        deskLocked(height: geo.size.height)
                    } else {
                        deskBanner
                        deskChips
                        deskBody(height: geo.size.height)
                    }
                }
                .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Desk.bg)
    }

    // MARK: head — h2 + region select

    private var deskHead: some View {
        HStack {
            Text("Live TV").font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.fg)
            Spacer()
            if !locked {
                Menu {
                    ForEach(DeskLive.regions, id: \.0) { code, label in
                        Button(label) { setRegion(code) }
                    }
                } label: {
                    Text(DeskLive.regions.first { $0.0 == region }?.1 ?? "🇺🇸 USA")
                        .font(.system(size: 14.4)).foregroundStyle(DeskLive.selectFg)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 11.2).padding(.vertical, 7.2)
                .background(Desk.card2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskLive.border, lineWidth: 1))
                .help("Region")
            }
        }
        .padding(.vertical, 8)
    }

    private func deskLocked(height: CGFloat) -> some View {
        VStack(spacing: 14) {
            Text("🔒").font(.system(size: 56))
            Text("CouchKing Live TV — Locked").font(.system(size: 26, weight: .heavy)).foregroundStyle(Desk.fg)
            Text("Live TV isn't part of your plan. Contact support to unlock it.")
                .font(.system(size: 15)).foregroundStyle(Desk.hex(0x9A9AA4))
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: height * 0.6)
    }

    // MARK: live-games banner (.lvb-*)

    @ViewBuilder private var deskBanner: some View {
        let sports = regionSports
        let soon = Array(sports.flatMap { sp in sp.soon.map { EmojiGame(emoji: sp.emoji, game: $0) } }
            .sorted { $0.game.s < $1.game.s }.prefix(25))
        if !sports.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sports.filter { !$0.live.isEmpty }) { sp in
                    (Text("\(sp.emoji) \(sp.sport) — ") + Text("LIVE NOW").foregroundColor(DeskLive.red))
                        .font(.system(size: 14.7, weight: .bold)).foregroundStyle(DeskLive.selectFg)
                        .padding(.top, 6.4).padding(.bottom, 7.2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9.6) {
                            ForEach(sp.live) { g in DeskGameCard(title: g.t, meta: "LIVE", ch: g.ch, live: true) { tune = g.meta } }
                        }
                        .padding(.bottom, 4.8)
                    }
                }
                if !soon.isEmpty {
                    Text("📅 Upcoming games").font(.system(size: 14.7, weight: .bold)).foregroundStyle(DeskLive.selectFg)
                        .padding(.top, 6.4).padding(.bottom, 7.2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9.6) {
                            ForEach(soon) { eg in
                                DeskGameCard(title: eg.emoji + " " + eg.game.t, meta: eg.game.when, ch: eg.game.ch,
                                             live: false) { tune = eg.game.meta }
                            }
                        }
                        .padding(.bottom, 4.8)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: chips + inline search (.lv-chips)

    private var deskChips: some View {
        FlowRow(spacing: 6.4) {
            ForEach(chips, id: \.self) { c in
                DeskLiveChip(text: c, on: chip == c && !searching) { q = ""; setChip(c) }
            }
            TextField("🔎 Channels & shows", text: $q)
                .textFieldStyle(.plain)
                .font(.system(size: 14)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(width: 220)
                .background(Desk.hex(0x1C1C22), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Desk.hex(0x3A3A44), lineWidth: 1))
                .onSubmit { searchTask?.cancel(); Task { await runSearch() } }
        }
        .padding(.top, 9.6).padding(.bottom, 16)
    }

    // MARK: body

    @ViewBuilder private func deskBody(height: CGFloat) -> some View {
        if searching {
            if catalog.isEmpty { DeskLive.loadingText(loading ? "Loading…" : "No channels or shows match.") }
            ForEach(catalog) { m in metaRow(m) }
        } else if chip == "Guide" {
            if guide.channels.isEmpty {
                DeskLive.loadingText("Loading the guide…")
            } else {
                DeskEPG(guide: guide, day: $day, now: now, height: max(320, height - 260),
                        onTune: { tuneChannel($0) }, onFav: { toggleFav($0) })
            }
        } else if chip == "★ Favorites" {
            if guide.favChannels.isEmpty {
                DeskLive.loadingText("No favorites yet — hit the ★ on any channel (search finds the hidden ones).")
            }
            ForEach(guide.favChannels) { ch in channelRow(ch) }
        } else if catalogChip {
            if catalog.isEmpty { DeskLive.loadingText(loading ? "Loading…" : "No channels in this category right now.") }
            ForEach(catalog) { m in metaRow(m) }
        } else {
            let list = guide.channels.filter { $0.section == chip }
            if list.isEmpty { DeskLive.loadingText("Nothing here right now.") }
            ForEach(list) { ch in channelRow(ch) }
        }
    }

    private func channelRow(_ ch: LiveChannel) -> some View {
        let n = ch.now(now), nx = ch.next(now)
        return DeskLiveRow(name: ch.name, logo: ch.logo, nowT: n?.t ?? "", nowS: n?.s ?? 0, nowE: n?.e ?? 0,
                           next: nx.map { "Next: \($0.t) • \(LiveTV.clock($0.s))" } ?? "",
                           at: now, fav: guide.favs.contains(ch.id),
                           onFav: { toggleFav(ch) }, onPlay: { tuneChannel(ch) })
    }

    private func metaRow(_ m: Meta) -> some View {
        let id = m.id.replacingOccurrences(of: "cklive:", with: "")
        let line = (m.description ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return DeskLiveRow(name: m.name, logo: m.poster ?? m.logo ?? "", nowT: line, nowS: 0, nowE: 0, next: "",
                           at: now, fav: guide.favs.contains(id),
                           onFav: { toggleFavId(id, channel: nil) }, onPlay: { tune = m })
    }
}

enum DeskLive {
    static let regions: [(String, String)] = [("", "🇺🇸 USA"), ("UK", "🇬🇧 UK"), ("CA", "🇨🇦 Canada")]
    static let border = Desk.hex(0x3A3560)
    static let selectFg = Desk.hex(0xE8E4F8)
    static let chipFg = Desk.hex(0xCFC9EA)
    static let dim = Desk.hex(0x9B93C0)
    static let red = Desk.hex(0xE94B6A)
    static let favOn = Desk.hex(0xF5C542)
    static let favOff = Desk.hex(0x4A4470)
    static let epgBg = Desk.hex(0x14102A), epgBorder = Desk.hex(0x2C2749), epgLine = Desk.hex(0x221D3E)
    static let epgHead = Desk.hex(0x171232), secBg = Desk.hex(0x1B1636), secFg = Desk.hex(0xA08EF0)
    static let block = Desk.hex(0x241F3D), blockBorder = Desk.hex(0x322C55), blockOn = Desk.hex(0x33285F)

    /// `.lv-loading`: muted, centered, 2rem padding.
    static func loadingText(_ t: String) -> some View {
        Text(t).font(.system(size: 14)).foregroundStyle(dim)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

/// `.lv-chip` — #241f3d pill, #cfc9ea text, 1px #3a3560 border; `.on` = accent.
struct DeskLiveChip: View {
    let text: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 13.6)).foregroundStyle(on ? .white : DeskLive.chipFg)
                .padding(.horizontal, 14.4).padding(.vertical, 5.6)
                .background(on ? Desk.accent : Desk.card2, in: Capsule())
                .overlay(Capsule().stroke(on ? Desk.accent : DeskLive.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// `.lvb-card` — game card; live = #2c1830 with a #7d2540 border and a pulsing red dot.
struct DeskGameCard: View {
    let title: String, meta: String, ch: String
    let live: Bool
    let action: () -> Void
    @State private var pulse = false
    var body: some View {
        Hovering { hover in
            Button(action: action) {
                VStack(alignment: .leading, spacing: 3.2) {
                    Text(title).font(.system(size: 13.4, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 0) {
                        if live {
                            Circle().fill(DeskLive.red).frame(width: 7, height: 7).opacity(pulse ? 0.35 : 1)
                                .padding(.trailing, 5.6)
                                .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true } }
                        }
                        Text("\(meta) • \(ch)").lineLimit(1)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(DeskLive.dim)
                }
                .padding(.horizontal, 12).padding(.vertical, 8.8)
                .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
                .background(live ? Desk.hex(0x2C1830) : Desk.card2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(hover ? Desk.accent : (live ? Desk.hex(0x7D2540) : DeskLive.border), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// `.lvg-chrow` — logo + name (200) | now title, red progress bar, times | "Next: …" (220) | ☆ ▶.
struct DeskLiveRow: View {
    let name: String, logo: String, nowT: String, nowS: Int, nowE: Int, next: String
    let at: Int
    let fav: Bool
    let onFav: () -> Void
    let onPlay: () -> Void
    @State private var starred: Bool?

    var body: some View {
        let on = starred ?? fav
        let pct = nowE > nowS ? min(1, max(0, Double(at - nowS) / Double(nowE - nowS))) : 0
        return Hovering { hover in
            HStack(spacing: 14.4) {
                HStack(spacing: 9.6) {
                    AsyncImage(url: URL(string: logo)) { img in img.resizable().aspectRatio(contentMode: .fit) }
                        placeholder: { Color.clear }
                        .frame(width: 44, height: 34)
                    Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .frame(width: 200, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    if nowT.isEmpty {
                        Text("Live programming").font(.system(size: 13.8)).foregroundStyle(DeskLive.dim)
                    } else {
                        Text(nowT).font(.system(size: 13.8)).foregroundStyle(.white).lineLimit(1)
                        if nowE > nowS {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Desk.hex(0x2B2547))
                                    RoundedRectangle(cornerRadius: 3).fill(Desk.hex(0xE63946))
                                        .frame(width: g.size.width * pct)
                                        .opacity(nowE - nowS >= 4 * 3_600_000 ? 0.3 : 1)   // marathon 24/7 blocks dim
                                }
                            }
                            .frame(height: 4).padding(.top, 4.8).padding(.bottom, 3.2)
                            Text("\(LiveTV.clock(nowS)) – \(LiveTV.clock(nowE))")
                                .font(.system(size: 11.2)).foregroundStyle(DeskLive.dim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(next).font(.system(size: 12.2)).foregroundStyle(DeskLive.dim).lineLimit(1)
                    .frame(width: 220, alignment: .leading)
                HStack(spacing: 6) {
                    Button { starred = !on; onFav() } label: {
                        Text(on ? "★" : "☆").foregroundStyle(on ? DeskLive.favOn : .white)
                            .frame(width: 34, height: 34).background(Desk.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    Button(action: onPlay) {
                        Text("▶").foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Desk.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12.8).padding(.vertical, 8.8)
            .background(Desk.hex(0x17132A), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? Desk.accent : Color.white.opacity(0.05), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)
            .padding(.bottom, 7.2)
        }
    }
}

/// The classic EPG (lvRenderGuide): day chips (Today · Tomorrow · weekday · weekday), the
/// "Continue watching — Live TV" strip (Today only), then the bordered grid — its own scroll
/// area (max-height 100vh − 260px) with the time header pinned on top and the 210px channel
/// column pinned left; the timeline pans sideways (trackpad / shift-wheel) and every row, the
/// ticks and the corner date follow it. Today spans 72h from the current half hour; other days
/// 24h from 6 AM.
struct DeskEPG: View {
    let guide: LiveGuide
    @Binding var day: Int
    let now: Int
    let height: CGFloat
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void
    @State private var x: CGFloat = 0
    @State private var laneViewW: CGFloat = 1200
    @State private var hovering = false
    @State private var monitor: Any?

    static let slotW: CGFloat = 260, colW: CGFloat = 210, rowH: CGFloat = 56, hdrH: CGFloat = 30

    private var t0: Int { LiveTV.dayStart(day, now: now) }
    private var slots: Int { day == 0 ? 144 : 48 }
    private var tEnd: Int { t0 + slots * 1_800_000 }
    private var laneW: CGFloat { CGFloat(slots) * Self.slotW }
    private func px(_ ms: Int) -> CGFloat { max(0, CGFloat(ms - t0) / 1_800_000 * Self.slotW) }
    private var maxX: CGFloat { max(0, laneW - laneViewW) }

    enum Line: Identifiable {
        case header(String), channel(LiveChannel)
        var id: String { switch self { case .header(let t): return "h:" + t; case .channel(let c): return "c:" + c.id } }
    }
    private var lines: [Line] {
        let favs = Set(guide.favs)
        var out: [Line] = []
        let favRows = guide.channels.filter { favs.contains($0.id) }
        if !favRows.isEmpty { out.append(.header("★ Favorites")); out += favRows.map { .channel($0) } }
        var last: String?
        for c in guide.channels where !favs.contains(c.id) {
            let sec = c.section.isEmpty ? "More Channels" : c.section
            if sec != last { out.append(.header(sec)); last = sec }
            out.append(.channel(c))
        }
        return out
    }
    private var recent: [LiveChannel] {
        guide.recent.compactMap { id in guide.channels.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6.4) {
                ForEach(0..<4, id: \.self) { d in
                    DeskLiveChip(text: d < 2 ? LiveTV.dayLabel(d, now: now) : LiveTV.day(now + d * 86_400_000, "EEEE"),
                                 on: d == day) { day = d; x = 0 }
                }
            }
            .padding(.bottom, 11.2)
            if !recent.isEmpty && day == 0 { recentStrip }
            grid
        }
    }

    // `.lvcw`
    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 7.2) {
            Text("Continue watching — Live TV").font(.system(size: 14.4, weight: .bold)).foregroundStyle(DeskLive.chipFg)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9.6) {
                    ForEach(recent) { c in
                        Hovering { hover in
                            Button { onTune(c) } label: {
                                HStack(spacing: 8.8) {
                                    AsyncImage(url: URL(string: c.logo)) { img in img.resizable().aspectRatio(contentMode: .fit) }
                                        placeholder: { Color.clear }
                                        .frame(width: 34, height: 34)
                                        .background(DeskLive.epgHead, in: RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.name).font(.system(size: 13.1, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                        Text(c.now(now)?.t ?? "Live").font(.system(size: 11.5)).foregroundStyle(DeskLive.dim)
                                            .lineLimit(1).frame(maxWidth: 170, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 11.2).padding(.vertical, 8)
                                .frame(minWidth: 180, maxWidth: 240, alignment: .leading)
                                .background(Desk.card2, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? Desk.accent : DeskLive.border, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 4.8)
            }
        }
        .padding(.bottom, 16)
    }

    // `.epg`
    private var grid: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: header) {
                    ForEach(lines) { line in
                        switch line {
                        case .header(let t): secHeader(t)
                        case .channel(let c): row(c)
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .background(DeskLive.epgBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DeskLive.epgBorder, lineWidth: 1))
        .background(GeometryReader { g in Color.clear.onAppear { laneViewW = max(200, g.size.width - Self.colW) }
            .onChange(of: g.size.width) { w in laneViewW = max(200, w - Self.colW) } })
        .onHover { hovering = $0 }
        .onAppear { installWheel() }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
        .onChange(of: day) { _ in x = 0 }
    }

    /// Sideways pan: trackpad horizontal swipes and shift + mouse wheel move the shared timeline.
    private func installWheel() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard hovering, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
            let step = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 12
            x = min(max(0, x - step), maxX)
            return nil
        }
    }

    /// Visible window of the lane (a screen of slack either side).
    private var visible: ClosedRange<CGFloat> { (x - laneViewW)...(x + 2 * laneViewW) }

    // `.epg-hrow` — corner date follows the scroll across midnight
    private var header: some View {
        HStack(spacing: 0) {
            Text(LiveTV.day(t0 + Int(x / Self.slotW * 1_800_000), "EEE, M/d").uppercased())
                .font(.system(size: 11.8)).kerning(0.7).foregroundStyle(DeskLive.dim)
                .padding(.horizontal, 8.8)
                .frame(width: Self.colW, height: Self.hdrH, alignment: .leading)
                .background(DeskLive.epgHead)
                .overlay(alignment: .trailing) { Rectangle().fill(DeskLive.epgBorder).frame(width: 1) }
            LaneLayout {
                ForEach(0..<slots, id: \.self) { i in
                    let lx = CGFloat(i) * Self.slotW
                    if visible.contains(lx) {
                        Text(LiveTV.clock(t0 + i * 1_800_000)).font(.system(size: 11.5)).foregroundStyle(DeskLive.dim)
                            .padding(.leading, 8).padding(.top, 5.6)
                            .frame(width: Self.slotW, height: Self.hdrH, alignment: .topLeading)
                            .overlay(alignment: .leading) { Rectangle().fill(DeskLive.epgLine).frame(width: 1) }
                            .layoutValue(key: LaneX.self, value: lx - x)
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(height: Self.hdrH).clipped()
        }
        .background(DeskLive.epgHead)
        .overlay(alignment: .bottom) { Rectangle().fill(DeskLive.epgLine).frame(height: 1) }
    }

    // `.epg-sechdr`
    private func secHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 12.5, weight: .bold)).kerning(0.6).foregroundStyle(DeskLive.secFg)
            .padding(.horizontal, 8.8).padding(.vertical, 5.6)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(DeskLive.secBg)
            .overlay(alignment: .bottom) { Rectangle().fill(DeskLive.epgLine).frame(height: 1) }
    }

    // `.epg-row`
    private func row(_ c: LiveChannel) -> some View {
        let fav = guide.favs.contains(c.id)
        let progs = c.progs.filter { $0.e > t0 && $0.s < tEnd }
        return HStack(spacing: 0) {
            HStack(spacing: 7.2) {
                DeskFavStar(on: fav) { onFav(c) }
                AsyncImage(url: URL(string: c.logo)) { img in img.resizable().aspectRatio(contentMode: .fit) }
                    placeholder: { Color.clear }
                    .frame(width: 30, height: 30)
                    .background(Desk.hex(0x100D20), in: RoundedRectangle(cornerRadius: 6))
                Text(c.name).font(.system(size: 12.8, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.horizontal, 8.8)
            .frame(width: Self.colW, height: Self.rowH, alignment: .leading)
            .background(DeskLive.epgHead)
            .overlay(alignment: .trailing) { Rectangle().fill(DeskLive.epgBorder).frame(width: 1) }
            .contentShape(Rectangle())
            .onTapGesture { onTune(c) }
            LaneLayout {
                // half-hour gridlines (repeating-linear-gradient every 260px)
                ForEach(0..<slots, id: \.self) { i in
                    let lx = CGFloat(i + 1) * Self.slotW - 1
                    if visible.contains(lx) {
                        Rectangle().fill(DeskLive.epgLine).frame(width: 1, height: Self.rowH)
                            .layoutValue(key: LaneX.self, value: lx - x)
                    }
                }
                if progs.isEmpty {
                    DeskEPGBlock(title: day > 0 ? "No guide data for this day" : "Live programming", time: "",
                                 tip: "", on: false, width: min(laneW, x + 2 * laneViewW) - 4) { onTune(c) }
                        .opacity(0.55)
                        .layoutValue(key: LaneX.self, value: -x)
                } else {
                    ForEach(progs, id: \.self) { p in
                        let l = px(p.s), r = min(px(p.e), laneW)
                        if r >= visible.lowerBound && l <= visible.upperBound {
                            DeskEPGBlock(title: p.t, time: LiveTV.clock(p.s),
                                         tip: "\(p.t) (\(LiveTV.clock(p.s))–\(LiveTV.clock(p.e)))",
                                         on: p.s <= now && p.e > now, width: max(r - l - 4, 40)) { onTune(c) }
                                .layoutValue(key: LaneX.self, value: l - x)
                        }
                    }
                }
                if day == 0 {
                    Rectangle().fill(DeskLive.red).frame(width: 2, height: Self.rowH)
                        .allowsHitTesting(false)
                        .layoutValue(key: LaneX.self, value: px(now) - x)
                }
            }
            .frame(maxWidth: .infinity).frame(height: Self.rowH).clipped()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DeskLive.epgLine).frame(height: 1) }
    }
}

/// `.epg-fav` — #4a4470 star, hover #cfc9ea, on #f5c542.
struct DeskFavStar: View {
    let on: Bool
    let action: () -> Void
    @State private var flipped: Bool?
    var body: some View {
        let isOn = flipped ?? on
        Hovering { hover in
            Button { flipped = !isOn; action() } label: {
                Text("★").font(.system(size: 16))
                    .foregroundStyle(isOn ? DeskLive.favOn : (hover ? DeskLive.chipFg : DeskLive.favOff))
            }
            .buttonStyle(.plain)
        }
        .onChange(of: on) { _ in flipped = nil }
    }
}

/// `.epg-block` — top/bottom 5px, #241f3d with a #322c55 border (accent on hover), r8;
/// the airing block `.on` = #33285f with an accent border.
struct DeskEPGBlock: View {
    let title: String, time: String, tip: String
    let on: Bool
    let width: CGFloat
    let action: () -> Void
    var body: some View {
        Hovering { hover in
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12.2, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !time.isEmpty { Text(time).font(.system(size: 10.9)).foregroundStyle(DeskLive.dim).lineLimit(1) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4.8)
            .frame(width: max(0, width), height: DeskEPG.rowH - 10, alignment: .topLeading)
            .background(on ? DeskLive.blockOn : DeskLive.block, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on || hover ? Desk.accent : DeskLive.blockBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(tip)
        }
        .padding(.top, 5)
    }
}
#endif
