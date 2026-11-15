import SwiftUI
import ImageIO

// GUIDE V2 ("guidev2", default OFF) — the Android GuideCanvas.kt engine ported to SwiftUI:
// the whole EPG grid is PAINTED on one Canvas from two camera values (scrollY, shiftX) plus a
// cursor that is pure state — no per-cell views, no focus engine inside the grid, so the cursor
// can never desync and a horizontal pan is one redraw (GUIDE-V3-SPEC.md, the Kodi
// GUIEPGGridContainer / AOSP Live Channels / TiviMate model). Mechanics kept from Android:
//  - cursor vs camera separated; the camera only moves to keep the cursor visible
//  - TRAVEL AXIS: ↑/↓ keeps you at the time you were browsing, not each entry's start (AOSP)
//  - labels PIN to the viewport edge while long programmes scroll past (Kodi width-truncate)
//  - gaps are real entries (one full-span "Live programming" filler for no-EPG channels)
//  - 🔴 live-sports sections from games.json merged on top (red headers + red live cells),
//    ★ Favorites pinned first, then the lineup under purple SECTION headers
//  - now-line #E94B6A; accent-tinted live/focus cells; logos decode async into a CGImage cache
// iPhone/Mac: drag pans both axes, tap = tune, long-press = ★ toggle, day tabs.
// Apple TV: the canvas is ONE focusable view; d-pad moves the painted cursor (onMoveCommand),
// select tunes, long-press ★s, Menu snaps back to now when scrolled away.
// Hosted by LiveTVView behind the synced per-profile `guidev2` pref (Settings → "Live TV
// canvas guide (beta)"); the classic GuideGrid/TVGuide stays the default until device-tested.
struct GuideCanvasView: View {
    let guide: LiveGuide
    let sports: [LiveSport]
    @Binding var day: Int
    let now: Int
    let height: CGFloat
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void

    @State private var model = GCModel()
    @State private var shiftX: CGFloat = 0      // horizontal camera (px into the timeline)
    @State private var scrollY: CGFloat = 0     // vertical camera (px into the row stack)
    @State private var curRow = -1              // cursor (pure state, tvOS d-pad)
    @State private var curEntry = 0
    @State private var inChannelCol = true
    @State private var travelMs = -1            // travel axis: the time ↑/↓ keeps you at
    @State private var cursorChannel: String? = nil
    @State private var panStart: CGPoint? = nil
    @State private var logoTick = 0             // bumped when a logo decodes → repaint
    #if os(tvOS)
    @FocusState private var gcFocus: Bool
    #endif

    private var dayStart: Int { LiveTV.dayStart(day, now: now) }
    private var winEnd: Int { dayStart + (day == 0 ? 72 : 24) * 3_600_000 }
    private var timelinePx: CGFloat { CGFloat((winEnd - dayStart) / 60_000) * GCS.pxPerMin }
    /// Rebuild key: day window, guide fetch stamp, favorites order, live-game channels.
    private var modelKey: String {
        let liveSig = sports.flatMap { $0.live.map(\.chid) }.joined(separator: ",")
        return "\(day)|\(dayStart)|\(guide.at)|\(guide.channels.count)|\(guide.favs.joined(separator: ","))|\(liveSig)"
    }
    private var hasFocus: Bool {
        #if os(tvOS)
        return gcFocus
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dayTabs
            GeometryReader { geo in
                canvasBody(geo.size)
            }
            .frame(height: height)
            .padding(.horizontal, Platform.gutter)
        }
        .task(id: modelKey) { rebuild() }
        .onChange(of: day) { _ in
            shiftX = 0; scrollY = 0; travelMs = -1; curEntry = 0; inChannelCol = true
        }
    }

    // MARK: day tabs (session-only, always opens on Today)

    private var dayTabs: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { d in
                #if os(tvOS)
                Button { day = d } label: {
                    Text(LiveTV.dayLabel(d, now: now))
                        .font(.system(size: TV.sp(12.5))).foregroundStyle(d == day ? .white : TV.dim)
                        .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(5))
                        .background(d == day ? TVLive.tabOn : TVLive.searchBg, in: RoundedRectangle(cornerRadius: TV.dp(14)))
                }
                .buttonStyle(TVRingButton(radius: TV.dp(14)))
                #else
                Button(LiveTV.dayLabel(d, now: now)) { day = d }
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(day == d ? Theme.panel : .clear, in: Capsule())
                    .overlay(Capsule().stroke(day == d ? Theme.accent : Theme.card, lineWidth: 1))
                    .foregroundStyle(.primary)
                #endif
            }
        }
        .padding(.horizontal, Platform.gutter)
        .ckFocusSection()
    }

    // MARK: the canvas + input (gestures on touch/pointer, move commands on tvOS)

    @ViewBuilder private func canvasBody(_ size: CGSize) -> some View {
        let _ = logoTick   // repaint when an async logo lands
        let canvas = Canvas { ctx, _ in
            draw(ctx, size)
        }
        #if os(tvOS)
        canvas
            .focusable()
            .focused($gcFocus)
            .onMoveCommand { move($0, size) }
            .onTapGesture { tuneCursor() }
            .onLongPressGesture(minimumDuration: 0.5) { favCursor() }
            // Menu while scrolled away from now: snap back (BACK layer 1); otherwise default.
            .onExitCommand(perform: exitAction(size))
        #else
        canvas
            // tap = move cursor + tune (the canvas maps the point itself)
            .gesture(SpatialTapGesture().onEnded { v in _ = tapAt(v.location, size: size, tune: true) })
            // drag pans BOTH axes; high priority so the page ScrollView can't steal vertical
            // drags (Android: requestDisallowInterceptTouchEvent)
            .highPriorityGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { g in
                        if panStart == nil { panStart = CGPoint(x: shiftX, y: scrollY) }
                        guard let p = panStart else { return }
                        shiftX = min(max(0, p.x - g.translation.width), maxShift(size.width))
                        scrollY = min(max(0, p.y - g.translation.height), maxScrollY(size.height))
                    }
                    .onEnded { _ in panStart = nil }
            )
            // long-press = ★ toggle; the sequenced drag carries the press location. A real
            // pan cancels the long press (movement fails it), so the gestures coexist.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { v in
                        if case .second(true, let d) = v, let loc = d?.location { favAt(loc, size) }
                    }
            )
        #endif
    }

    // MARK: model (rows rebuilt off guide + games; cursor restored by channel id)

    private func rebuild() {
        var rows: [GCRow] = []
        let favs = Set(guide.favs)
        // favorited channels OUTSIDE the default lineup (locals, UK/CA): the server ships
        // them whole in favChannels exactly for this (Android Nov 14 merge).
        var all = guide.channels
        var seen = Set(all.map(\.id))
        for fc in guide.favChannels where favs.contains(fc.id) && !seen.contains(fc.id) {
            all.append(fc); seen.insert(fc.id)
        }
        func chRow(_ c: LiveChannel, red: Bool) -> GCRow {
            GCRow(header: nil, channel: c, name: gcCleanName(c.name),
                  progs: c.progs.filter { $0.e > dayStart && $0.s < winEnd },
                  red: red, fav: favs.contains(c.id))
        }
        func hdr(_ t: String, red: Bool = false) -> GCRow {
            GCRow(header: t, channel: nil, name: "", progs: [], red: red, fav: false)
        }
        // ★ Favorites FIRST, then the 🔴 live sections, then the lineup (Android order).
        let favList = all.filter { favs.contains($0.id) }
        if !favList.isEmpty {
            rows.append(hdr("★ Favorites"))
            rows += favList.map { chRow($0, red: false) }
        }
        // 🔴 per-sport LIVE sections (games.json): only games live RIGHT NOW, red headers,
        // their rows draw live cells red. Finished games fall off on the next games refresh.
        var used = Set<String>()
        for sp in sports where !sp.live.isEmpty {
            var sec: [GCRow] = []
            for g in sp.live {
                let cid = g.chid.replacingOccurrences(of: "cklive:", with: "")
                guard !used.contains(cid),
                      let c = guide.channels.first(where: { $0.id == cid }) else { continue }
                used.insert(cid)
                sec.append(chRow(c, red: true))
            }
            if !sec.isEmpty {
                rows.append(hdr("🔴 \(sp.emoji) \(sp.sport.uppercased()) — LIVE", red: true))
                rows += sec
            }
        }
        // the lineup grouped under SECTION headers
        var last = ""
        for c in all where !favs.contains(c.id) {
            let s = !c.section.isEmpty ? c.section : (!c.genre.isEmpty ? c.genre : "More Channels")
            if s != last { last = s; rows.append(hdr(s)) }
            rows.append(chRow(c, red: false))
        }
        var y: [CGFloat] = [0]
        for r in rows { y.append(y[y.count - 1] + (r.channel != nil ? GCS.rowH + 2 : GCS.hdrH)) }
        model = GCModel(rows: rows, rowY: y, contentH: y[rows.count])
        // cursor follows the channel by id across rebuilds (fav re-sort, 60s section refresh)
        if let keep = cursorChannel, let idx = rows.firstIndex(where: { $0.channel?.id == keep }) {
            curRow = idx
        } else if !model.rows.indices.contains(curRow) || model.rows[curRow].channel == nil {
            curRow = rows.firstIndex(where: { $0.channel != nil }) ?? 0
            inChannelCol = true
        }
        if let row = rowAt(curRow) { curEntry = min(curEntry, entryCount(row) - 1) }
        scrollY = min(scrollY, max(0, model.contentH - max(1, height - GCS.rulerH)))
    }

    // MARK: cursor/camera mechanics (ported 1:1 from GuideCanvas.kt)

    private func rowAt(_ i: Int) -> GCRow? { model.rows.indices.contains(i) ? model.rows[i] : nil }

    private func nextChannelRow(_ from: Int, _ dir: Int) -> Int {
        var i = from + dir
        while model.rows.indices.contains(i) {
            if model.rows[i].channel != nil { return i }
            i += dir
        }
        return -1
    }

    private func moveRow(_ target: Int, _ size: CGSize) {
        curRow = target
        cursorChannel = rowAt(target)?.channel?.id
        if !inChannelCol, let row = rowAt(target) {
            // travel axis (AOSP): land on the entry at the time you were browsing
            curEntry = entryAtTime(row, travelMs > 0 ? travelMs : viewLeftMs() + 60_000)
        }
        ensureRowVisible(size)
    }

    private func ensureRowVisible(_ size: CGSize) {
        guard curRow >= 0, curRow < model.rows.count else { return }
        let viewH = max(1, size.height - GCS.rulerH)
        let top = model.rowY[curRow], bot = model.rowY[curRow + 1]
        // keep one row of context above when possible
        if top - scrollY < GCS.rowH / 2 {
            scrollY = max(0, top - GCS.rowH - 2)
        } else if bot - scrollY > viewH {
            scrollY = min(bot - viewH, max(0, model.contentH - viewH))
        }
    }

    private func ensureEntryVisible(_ size: CGSize) {
        guard let row = rowAt(curRow), row.channel != nil else { return }
        let laneW = max(1, size.width - GCS.colW)
        let l = xOfTime(entryStart(row, curEntry)) + shiftX - GCS.colW   // absolute px
        let r = xOfTime(entryEnd(row, curEntry)) + shiftX - GCS.colW
        var target = shiftX
        if r - shiftX > laneW { target = r - l >= laneW ? l : r - laneW }
        if l - target < 0 { target = l }
        shiftX = min(max(0, target), maxShift(size.width))
    }

    private func maxShift(_ w: CGFloat) -> CGFloat { max(0, timelinePx - (w - GCS.colW)) }
    private func maxScrollY(_ h: CGFloat) -> CGFloat { max(0, model.contentH - (h - GCS.rulerH)) }
    private func viewLeftMs() -> Int { dayStart + Int(shiftX / GCS.pxPerMin) * 60_000 }
    private func xOfTime(_ t: Int) -> CGFloat {
        GCS.colW + CGFloat(t - dayStart) / 60_000 * GCS.pxPerMin - shiftX
    }

    // gap-as-entry: a channel with no progs gets ONE full-span synthetic entry
    private func entryCount(_ r: GCRow) -> Int { r.progs.isEmpty ? 1 : r.progs.count }
    private func entryStart(_ r: GCRow, _ i: Int) -> Int {
        r.progs.isEmpty ? dayStart : max(r.progs[min(max(i, 0), r.progs.count - 1)].s, dayStart)
    }
    private func entryEnd(_ r: GCRow, _ i: Int) -> Int {
        r.progs.isEmpty ? winEnd : min(r.progs[min(max(i, 0), r.progs.count - 1)].e, winEnd)
    }
    private func entryAtTime(_ r: GCRow, _ t: Int) -> Int {
        guard !r.progs.isEmpty else { return 0 }
        for i in r.progs.indices where r.progs[i].e > t { return i }
        return r.progs.count - 1
    }

    /// Menu/BACK while scrolled away: snap time to now + cursor to the airing entry.
    private func snapTarget(_ size: CGSize) -> CGFloat {
        let nowAbs = CGFloat(now - dayStart) / 60_000 * GCS.pxPerMin   // absolute px of now
        return min(max(0, nowAbs - 30), maxShift(size.width))
    }
    private func snapNeeded(_ size: CGSize) -> Bool { abs(snapTarget(size) - shiftX) > 8 }
    private func snapToNow(_ size: CGSize) {
        shiftX = snapTarget(size)
        if !inChannelCol, let row = rowAt(curRow),
           let i = row.progs.firstIndex(where: { $0.s <= now && $0.e > now }) {
            curEntry = i
        }
        travelMs = -1
    }

    // MARK: input actions

    /// Map a touch point to the cursor (row + entry); optionally tune. false = header/gap.
    private func tapAt(_ p: CGPoint, size: CGSize, tune: Bool) -> Bool {
        guard p.y >= GCS.rulerH, !model.rows.isEmpty else { return false }
        let cy = p.y - GCS.rulerH + scrollY
        guard let i = model.rows.indices.first(where: { cy >= model.rowY[$0] && cy < model.rowY[$0 + 1] }),
              let ch = model.rows[i].channel else { return false }
        curRow = i; cursorChannel = ch.id
        inChannelCol = p.x < GCS.colW
        if !inChannelCol {
            let t = viewLeftMs() + Int((p.x - GCS.colW) / GCS.pxPerMin * 60_000)
            curEntry = entryAtTime(model.rows[i], t)
            travelMs = entryStart(model.rows[i], curEntry)
        }
        if tune { onTune(ch) }
        return true
    }

    private func favAt(_ p: CGPoint, _ size: CGSize) {
        guard tapAt(p, size: size, tune: false), let ch = rowAt(curRow)?.channel else { return }
        onFav(ch)
    }

    private func tuneCursor() { if let ch = rowAt(curRow)?.channel { onTune(ch) } }
    private func favCursor() { if let ch = rowAt(curRow)?.channel { onFav(ch) } }

    #if os(tvOS)
    /// nil while the view sits at now — Menu then falls through to the page's default back.
    private func exitAction(_ size: CGSize) -> (() -> Void)? {
        snapNeeded(size) ? { snapToNow(size) } : nil
    }

    private func move(_ dir: MoveCommandDirection, _ size: CGSize) {
        switch dir {
        case .up, .down:
            let d = dir == .up ? -1 : 1
            let nxt = nextChannelRow(curRow, d)
            if nxt < 0 {
                // top of the grid: hand focus back to the page (chips/day tabs above)
                if d < 0 { gcFocus = false }
                return
            }
            moveRow(nxt, size)
        case .left:
            guard let row = rowAt(curRow) else { return }
            if inChannelCol { gcFocus = false; return }   // leave the grid (page handles it)
            if curEntry > 0 {
                curEntry -= 1; travelMs = entryStart(row, curEntry); ensureEntryVisible(size)
            } else { inChannelCol = true }
        case .right:
            guard let row = rowAt(curRow) else { return }
            if inChannelCol {
                inChannelCol = false
                curEntry = entryAtTime(row, viewLeftMs() + 60_000)
                travelMs = entryStart(row, curEntry)
            } else if curEntry < entryCount(row) - 1 {
                curEntry += 1; travelMs = entryStart(row, curEntry)
            }
            ensureEntryVisible(size)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: draw (the whole guide, every repaint, visible rows only)

    private func draw(_ root: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        root.fill(Path(CGRect(origin: .zero, size: size)), with: .color(GCC.bg))
        guard !model.rows.isEmpty else { return }
        let nowMs = now

        // ── ruler: date cell + 30-min ticks ──
        root.fill(Path(CGRect(x: 0, y: 0, width: GCS.colW, height: GCS.rulerH)), with: .color(GCC.secBg))
        drawText(root, LiveTV.day(viewLeftMs(), "EEE M/d"), size: GCS.fRuler, weight: .bold,
                 color: .white, at: CGPoint(x: 8, y: GCS.rulerH / 2))
        var ruler = root
        ruler.clip(to: Path(CGRect(x: GCS.colW, y: 0, width: max(0, w - GCS.colW), height: GCS.rulerH)))
        var tick = dayStart - dayStart % 1_800_000
        while tick < winEnd {
            let x = xOfTime(tick)
            if x > w { break }
            if x + 80 > GCS.colW {
                drawText(ruler, LiveTV.clock(tick), size: GCS.fRuler, color: GCC.dim,
                         at: CGPoint(x: x + 4, y: GCS.rulerH / 2))
            }
            tick += 1_800_000
        }

        // ── rows (visible window only) ──
        var rowsCtx = root
        rowsCtx.clip(to: Path(CGRect(x: 0, y: GCS.rulerH, width: w, height: max(0, h - GCS.rulerH))))
        var lane = root
        lane.clip(to: Path(CGRect(x: GCS.colW, y: GCS.rulerH, width: max(0, w - GCS.colW), height: max(0, h - GCS.rulerH))))
        let viewTop = scrollY, viewBot = scrollY + (h - GCS.rulerH)
        var i = model.rows.indices.first(where: { model.rowY[$0 + 1] > viewTop }) ?? 0
        while i < model.rows.count, model.rowY[i] < viewBot {
            let y0 = model.rowY[i] - scrollY + GCS.rulerH
            let row = model.rows[i]
            guard row.channel != nil else {   // section header band (🔴 sections draw RED)
                rowsCtx.fill(Path(CGRect(x: 0, y: y0, width: w, height: GCS.hdrH - 2)), with: .color(GCC.secBg))
                drawText(rowsCtx, (row.header ?? "").uppercased(), size: GCS.fSec, weight: .bold,
                         color: (row.header ?? "").hasPrefix("🔴") ? GCC.red : GCC.sec,
                         at: CGPoint(x: 8, y: y0 + (GCS.hdrH - 2) / 2))
                i += 1; continue
            }
            let focusRow = hasFocus && i == curRow
            // channel cell (pinned to the left edge — the lane scrolls past it)
            let chPath = Path(roundedRect: CGRect(x: 1, y: y0, width: GCS.colW - 3, height: GCS.rowH),
                              cornerRadius: 6)
            rowsCtx.fill(chPath, with: .color(GCC.chColBg))
            if focusRow && inChannelCol {
                rowsCtx.fill(chPath, with: .color(Theme.accent.opacity(0.6)))
                rowsCtx.stroke(chPath, with: .color(.white.opacity(0.7)), lineWidth: 2)
            }
            var tx: CGFloat = 7
            if let c = row.channel, !c.logo.isEmpty {
                if let cg = GuideLogoCache.shared.image(c.logo, onLoad: bumpLogos) {
                    rowsCtx.draw(Image(decorative: cg, scale: 1),
                                 in: CGRect(x: tx, y: y0 + (GCS.rowH - GCS.logo) / 2,
                                            width: GCS.logo, height: GCS.logo))
                }
                tx += GCS.logo + 6
            }
            var nameCtx = rowsCtx
            nameCtx.clip(to: Path(CGRect(x: tx, y: y0, width: max(0, GCS.colW - tx - 6), height: GCS.rowH)))
            drawText(nameCtx, (row.fav ? "★ " : "") + row.name, size: GCS.fCh, color: .white,
                     at: CGPoint(x: tx, y: y0 + GCS.rowH / 2))
            // programme cells
            if row.progs.isEmpty {
                drawCell(lane, x0: xOfTime(dayStart), x1: xOfTime(winEnd), y0: y0,
                         title: "Live programming", startMs: dayStart,
                         live: row.red, past: false,
                         focused: focusRow && !inChannelCol, showTime: false, red: row.red)
            } else {
                for (pi, p) in row.progs.enumerated() {
                    let x0 = xOfTime(max(p.s, dayStart))
                    let x1 = xOfTime(min(p.e, winEnd))
                    if x1 < GCS.colW { continue }
                    if x0 > w { break }
                    drawCell(lane, x0: x0, x1: x1, y0: y0, title: p.t, startMs: p.s,
                             live: p.s <= nowMs && p.e > nowMs, past: p.e <= nowMs,
                             focused: focusRow && !inChannelCol && pi == curEntry,
                             showTime: true, red: row.red)
                }
            }
            i += 1
        }

        // ── now line across the grid ──
        let nowX = xOfTime(nowMs)
        if nowX >= GCS.colW && nowX <= w {
            rowsCtx.fill(Path(CGRect(x: nowX, y: GCS.rulerH, width: 2, height: h - GCS.rulerH)),
                         with: .color(GCC.nowLine))
        }
    }

    private func drawCell(_ lane: GraphicsContext, x0: CGFloat, x1: CGFloat, y0: CGFloat,
                          title: String, startMs: Int,
                          live: Bool, past: Bool, focused: Bool, showTime: Bool, red: Bool) {
        let l = x0 + 1, r = x1 - 1
        guard r - l >= 3 else { return }
        let path = Path(roundedRect: CGRect(x: l, y: y0, width: r - l, height: GCS.rowH), cornerRadius: 6)
        // layered fills approximate Android's blendARGB: base, then accent/red at the blend ratio
        lane.fill(path, with: .color(past && !live && !focused ? GCC.cellPast : GCC.cellBase))
        if focused {
            lane.fill(path, with: .color(Theme.accent.opacity(0.6)))
        } else if live {
            lane.fill(path, with: .color(red ? GCC.red.opacity(0.3) : Theme.accent.opacity(0.2)))
        }
        lane.stroke(path, with: .color(focused ? .white.opacity(0.7) : GCC.cellLine),
                    lineWidth: focused ? 2 : 1)
        guard r - l >= 52 else { return }
        // LABEL PINNING (Kodi): text starts at the viewport edge while the cell hangs off-left
        let textL = max(l, GCS.colW) + 6
        let avail = r - textL - 6
        guard avail >= 30 else { return }
        var tctx = lane
        tctx.clip(to: Path(CGRect(x: textL, y: y0, width: avail, height: GCS.rowH)))
        drawText(tctx, title, size: GCS.fTitle, weight: .bold,
                 color: focused || live ? .white : (past ? GCC.pastTxt : GCC.dim),
                 at: CGPoint(x: textL, y: y0 + GCS.rowH * 0.32))
        if showTime {
            drawText(tctx, LiveTV.clock(startMs), size: GCS.fTime,
                     color: past ? GCC.pastTxt : GCC.timeTxt,
                     at: CGPoint(x: textL, y: y0 + GCS.rowH * 0.66))
        }
    }

    /// Resolved-text draw (crisp at any display scale — the Canvas rasterizes at device DPR).
    private func drawText(_ ctx: GraphicsContext, _ s: String, size: CGFloat,
                          weight: Font.Weight = .regular, color: Color,
                          at p: CGPoint, anchor: UnitPoint = .leading) {
        var t = ctx.resolve(Text(s).font(.system(size: size, weight: weight)))
        t.shading = .color(color)
        ctx.draw(t, at: p, anchor: anchor)
    }

    private func bumpLogos() { logoTick &+= 1 }
}

// MARK: - model rows

private struct GCRow {
    let header: String?
    let channel: LiveChannel?
    let name: String            // display name (provider junk cleaned), "" for headers
    let progs: [LiveProg]       // clipped to the day window
    let red: Bool               // row sits under a 🔴 section → live cells draw RED
    let fav: Bool
}

private struct GCModel {
    var rows: [GCRow] = []
    var rowY: [CGFloat] = [0]   // prefix y of each row (content coords, below the ruler)
    var contentH: CGFloat = 0
}

// MARK: - metrics + palette (GuideCanvas.kt, 1dp = 1pt phone/Mac, 1dp = 2pt Apple TV)

private enum GCS {
    #if os(tvOS)
    static let pxPerMin = TV.dp(4)
    static let rowH = TV.dp(56)
    static let hdrH = TV.dp(26)
    static let colW = TV.dp(150)
    static let rulerH = TV.dp(28)
    static let logo = TV.dp(24)
    static let fTitle = TV.sp(12), fTime = TV.sp(10), fCh = TV.sp(12), fSec = TV.sp(10), fRuler = TV.sp(11)
    #else
    static let pxPerMin: CGFloat = Platform.isMac ? 6 : 4
    static let rowH: CGFloat = Platform.isMac ? 60 : 56
    static let hdrH: CGFloat = 26
    static let colW: CGFloat = 150
    static let rulerH: CGFloat = 28
    static let logo: CGFloat = 24
    static let fTitle: CGFloat = 12, fTime: CGFloat = 10, fCh: CGFloat = 12, fSec: CGFloat = 10, fRuler: CGFloat = 11
    #endif
}

/// Palette = GuideCanvas.kt (the Nov 7 restyle / IPVIO consensus).
private enum GCC {
    static let bg = Color(hex: "#0C0B14")
    static let cellBase = Color(hex: "#1C202B")
    static let cellPast = Color(hex: "#15181F")
    static let cellLine = Color(hex: "#2A2F3B")
    static let chColBg = Color(hex: "#13101F")
    static let dim = Color(hex: "#A9A5C0")
    static let pastTxt = Color(hex: "#6F6A85")
    static let sec = Color(hex: "#A08EF0")
    static let secBg = Color(hex: "#1B1636")
    static let nowLine = Color(hex: "#E94B6A")
    static let red = Color(hex: "#E64545")
    static let timeTxt = Color(hex: "#8E88AA")
}

/// Event-feed channel names carry provider junk — "UFC: UFC Fight Night : English
/// 2026-11-07 22:00" → "UFC Fight Night" (GuideCanvas.kt ckCleanChannelName).
private func gcCleanName(_ n: String) -> String {
    var s = n
    s = s.replacingOccurrences(of: #"\s*[:\-–]?\s*\(?English\)?(?=\s|$)"#, with: " ",
                               options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: #"\(?\d{4}-\d{2}-\d{2}[ T]?[\d:]*\)?"#, with: "",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"^(UFC|NFL|NBA|MLB|NHL|NCAAF?B?\s*\d*|BOXING\s*\d*)\s*:\s*"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespaces)
    while let last = s.last, last == ":" || last == "-" || last == "–" { s.removeLast() }
    return s.trimmingCharacters(in: .whitespaces)
}

// MARK: - logo cache (async decode → CGImage cache → repaint callback)

/// Main-thread CGImage cache for channel logos — the Canvas can't host AsyncImage, so the
/// draw pass asks here; a miss kicks off a fetch and the decoded logo repaints via `onLoad`
/// (Android GuideCanvas logos map + Coil enqueue + invalidate).
final class GuideLogoCache {
    static let shared = GuideLogoCache()
    private var images: [String: CGImage] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()

    /// Call from the main thread (the Canvas renderer). Returns the cached logo or nil while
    /// (or after a failed) fetch; `onLoad` fires on main once a new logo decodes.
    func image(_ url: String, onLoad: @escaping () -> Void) -> CGImage? {
        if let img = images[url] { return img }
        guard !url.isEmpty, !pending.contains(url), !failed.contains(url),
              let u = URL(string: url) else { return nil }
        pending.insert(url)
        URLSession.shared.dataTask(with: u) { data, _, _ in
            let img = data.flatMap(GuideLogoCache.decode)
            DispatchQueue.main.async {
                self.pending.remove(url)
                if let img {
                    if self.images.count > 500 { self.images.removeAll() }   // crude trim
                    self.images[url] = img
                    onLoad()
                } else {
                    self.failed.insert(url)
                }
            }
        }.resume()
        return nil
    }

    private static func decode(_ d: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 128,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
