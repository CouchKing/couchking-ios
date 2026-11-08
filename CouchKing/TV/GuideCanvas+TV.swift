#if os(iOS)
import SwiftUI
import UIKit

// GUIDE V3 (Nov 7) — the iPhone TOUCH port of Android's canvas guide (couchking-tv
// GuideCanvas.kt + GUIDE-V3-SPEC.md): every program cell is painted in ONE draw(_:) pass from
// two camera values (scrollYpx, shiftPx) + a cursor that is pure state — no per-lane scrollers,
// no view churn, so panning both axes is one setNeedsDisplay and the cursor can never desync.
// Drag pans both axes, tap = select + tune, long-press = ★ favorite. Row model (Android
// liveRenderGuideRecycler): ★ Favorites FIRST, then 🔴 per-sport LIVE sections from games.json
// (refreshed every 60s, sig-gated, finished games fall off), then the lineup grouped under
// purple uppercase section headers. A fixed-height detail card above the grid shows the
// cursor's channel/title/time/progress + a lazily-fetched description (epgdesc.json, 250ms
// debounce, per-channel cache). Flip `ckUseGuideV3 = false` to fall back to the old GuideGrid
// page + mini-guide strip.

/// Master switch: the new canvas guide on the Live TV page + the corner-player guide overlay
/// in the live player. false = the old GuideGrid + side-strip mini guide, untouched.
let ckUseGuideV3 = true

/// Event-feed channel names carry provider junk — "UFC: UFC Fight Night : English
/// 2026-11-07 22:00" → "UFC Fight Night" (Android ckCleanChannelName, AJ Nov 7 "name it
/// properly please").
func ckCleanChannelName(_ n: String) -> String {
    var s = n
    func rep(_ pat: String, _ with: String) {
        s = s.replacingOccurrences(of: pat, with: with, options: [.regularExpression, .caseInsensitive])
    }
    rep("\\s*[:\\-–]?\\s*\\(?English\\)?(?=\\s|$)", " ")
    rep("\\(?\\d{4}-\\d{2}-\\d{2}[ T]?[\\d:]*\\)?", "")
    rep("^\\(\\d+\\)\\s*", "")
    rep("^(UFC|NFL|NBA|MLB|NHL|NCAAF?B?\\s*\\d*|BOXING\\s*\\d*)\\s*:\\s*", "")
    rep("\\s{2,}", " ")
    s = s.trimmingCharacters(in: .whitespaces)
    while let last = s.last, last == ":" || last == "-" || last == "–" { s.removeLast() }
    return s.trimmingCharacters(in: .whitespaces)
}

// MARK: - model

/// One guide line: a section header band OR a channel lane (Android GuideGrid.GuideRow).
struct CKGuideRow {
    var header: String? = nil
    var channel: LiveChannel? = nil
    var display = ""          // cleaned channel name, computed once at assembly
    init(header: String) { self.header = header }
    init(channel: LiveChannel) { self.channel = channel; display = ckCleanChannelName(channel.name) }
}

struct CKGuideModel {
    var rows: [CKGuideRow] = []
    var favs: Set<String> = []
    var dayStart = 0
    var winEnd = 0
    /// Change signature — the canvas only resubmits (cursor preserved by channel id) when
    /// this moves: day change, fav flip, section flip, a 🔴 game starting/ending.
    var sig = ""

    /// ★ Favorites first, then the 🔴 live sections (`top`), then the lineup under section
    /// headers — Android liveRenderGuideRecycler assemble(). A fav toggle re-sorts instantly
    /// because the host patches guide.favs and this rebuilds (AJ "can that be instant?").
    static func build(guide: LiveGuide, top: [CKGuideRow], dayStart: Int, winEnd: Int) -> CKGuideModel {
        let favs = Set(guide.favs)
        var rows: [CKGuideRow] = []
        let favList = guide.channels.filter { favs.contains($0.id) }
        if !favList.isEmpty {
            rows.append(CKGuideRow(header: "★ Favorites"))
            rows += favList.map { CKGuideRow(channel: $0) }
        }
        rows += top
        var lastSec = ""
        for c in guide.channels where !favs.contains(c.id) {
            let sec = !c.section.isEmpty ? c.section : (!c.genre.isEmpty ? c.genre : "More Channels")
            if sec != lastSec { rows.append(CKGuideRow(header: sec)); lastSec = sec }
            rows.append(CKGuideRow(channel: c))
        }
        var m = CKGuideModel(rows: rows, favs: favs, dayStart: dayStart, winEnd: winEnd)
        m.sig = "\(dayStart)|"
            + rows.map { $0.header ?? ($0.channel?.id ?? "") }.joined(separator: ",")
            + "|" + favs.sorted().joined(separator: ",")
        return m
    }
}

// MARK: - the canvas (UIKit, CoreGraphics)

fileprivate func ckRGB(_ v: Int) -> UIColor {
    UIColor(red: CGFloat((v >> 16) & 255) / 255.0, green: CGFloat((v >> 8) & 255) / 255.0,
            blue: CGFloat(v & 255) / 255.0, alpha: 1)
}
fileprivate func ckBlend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
}

/// The drawn grid itself. Pure port of GuideCanvas.kt minus the d-pad half (touch only):
/// ruler (date cell + 30-min ticks), section header bands (🔴 headers draw RED #E64545),
/// channel column (logo + ★ name), program cells (live = accent tint, live-in-red-section =
/// red tint, past dimmed, label PINS to the viewport edge while a long cell scrolls past),
/// red now-line. Gestures: pan (both axes, the canvas owns the drag so the page scroller
/// can't steal it), tap = cursor + tune, long-press = ★ toggle.
final class GuideCanvasUIView: UIView {
    // callbacks (host wiring — resubmit after a fav patch keeps the star + row order honest)
    var onTune: ((LiveChannel) -> Void)?
    var onFav: ((LiveChannel, Bool) -> Void)?          // desired new state
    var onCursor: ((LiveChannel, LiveProg?) -> Void)?

    // metrics (phone-scale; the old GuideGrid used 4px/min · 56pt rows too)
    let pxPerMin: CGFloat = 4
    let rowH: CGFloat = 56
    let hdrRowH: CGFloat = 26
    let chColW: CGFloat = 104
    let rulerH: CGFloat = 26

    // palette = Android GuideCanvas.kt
    private let bgCol = ckRGB(0x0C0B14)
    private let cellBase = ckRGB(0x1C202B)
    private let cellPast = ckRGB(0x15181F)
    private let cellLine = ckRGB(0x2A2F3B)
    private let chColBg = ckRGB(0x13101F)
    private let fgCol = UIColor.white
    private let dimCol = ckRGB(0xA9A5C0)
    private let pastTxt = ckRGB(0x6F6A85)
    private let secCol = ckRGB(0xA08EF0)
    private let secBgCol = ckRGB(0x1B1636)
    private let nowLineCol = ckRGB(0xE94B6A)
    private let redCol = ckRGB(0xE64545)
    private let timeCol = ckRGB(0x8E88AA)
    var accent = ckRGB(0x7B5BF5) { didSet { setNeedsDisplay() } }

    private let titleFont = UIFont.boldSystemFont(ofSize: 12)
    private let timeFont = UIFont.systemFont(ofSize: 10)
    private let chFont = UIFont.systemFont(ofSize: 12)
    private let secFont = UIFont.boldSystemFont(ofSize: 10)
    private let rulerFont = UIFont.systemFont(ofSize: 11)

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter(); f.timeZone = LiveTV.et; f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.timeZone = LiveTV.et; f.dateFormat = "EEE M/d"; return f
    }()
    private static func clock(_ ms: Int) -> String {
        clockFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // model + geometry
    private(set) var modelSig = ""
    private var rows: [CKGuideRow] = []
    private var favs: Set<String> = []
    private var redRow: [Bool] = []      // rows under a 🔴 header draw live cells RED
    private var rowY: [CGFloat] = [0]    // prefix y of each row (content coords, below ruler)
    private var contentH: CGFloat = 0
    private var dayStart = 0
    private var winEnd = 0

    // cursor (pure state) + camera
    private var cursorChannel: String?
    private var curRow = -1
    private var curEntry = 0
    private var inChannelCol = true
    private var shiftPx: CGFloat = 0     // horizontal camera (px into the timeline)
    private var scrollYpx: CGFloat = 0   // vertical camera (px into the row stack)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = bgCol
        isOpaque = true
        contentMode = .redraw   // rotation / layout changes repaint instead of stretching
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTap(_:))))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLong(_:)))
        long.minimumPressDuration = 0.45
        addGestureRecognizer(long)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func submit(_ model: CKGuideModel) {
        if model.dayStart != dayStart { shiftPx = 0; scrollYpx = 0; curEntry = 0; inChannelCol = true }
        dayStart = model.dayStart; winEnd = model.winEnd
        modelSig = model.sig
        rows = model.rows; favs = model.favs
        redRow = []; rowY = [0]
        var red = false
        for r in rows {
            if let h = r.header { red = h.hasPrefix("🔴") }
            redRow.append(red)
            rowY.append(rowY[rowY.count - 1] + (r.channel != nil ? rowH + 2 : hdrRowH))
        }
        contentH = rowY[rowY.count - 1]
        // cursor follows the channel by id across resubmits (fav re-sort, 🔴 section swap)
        if let keep = cursorChannel, let idx = rows.firstIndex(where: { $0.channel?.id == keep }) {
            curRow = idx
        }
        if !rows.indices.contains(curRow) || rows[curRow].channel == nil {
            curRow = rows.firstIndex(where: { $0.channel != nil }) ?? 0
            inChannelCol = true
        }
        cursorChannel = rows.indices.contains(curRow) ? rows[curRow].channel?.id : nil
        clampCamera()
        notifyCursor()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clampCamera()
        setNeedsDisplay()
    }

    // ── mapping ──
    private var timelinePx: CGFloat { CGFloat(winEnd - dayStart) / 60_000 * pxPerMin }
    private var maxShift: CGFloat { max(0, timelinePx - (bounds.width - chColW)) }
    private var maxScrollY: CGFloat { max(0, contentH - (bounds.height - rulerH)) }
    private func xOfTime(_ t: Int) -> CGFloat { chColW + CGFloat(t - dayStart) / 60_000 * pxPerMin - shiftPx }
    private func viewLeftMs() -> Int { dayStart + Int(shiftPx / pxPerMin) * 60_000 }
    private func clampCamera() {
        shiftPx = min(max(0, shiftPx), maxShift)
        scrollYpx = min(max(0, scrollYpx), maxScrollY)
    }

    private func entryAtTime(_ c: LiveChannel, _ t: Int) -> Int {
        guard !c.progs.isEmpty else { return 0 }
        for (i, p) in c.progs.enumerated() where p.e > t { return i }
        return c.progs.count - 1
    }
    private func nowProg(_ c: LiveChannel) -> LiveProg? {
        let n = LiveTV.nowMs()
        return c.progs.first { $0.s <= n && $0.e > n }
    }
    private func notifyCursor() {
        guard rows.indices.contains(curRow), let c = rows[curRow].channel else { return }
        let p = inChannelCol ? nowProg(c) : (c.progs.indices.contains(curEntry) ? c.progs[curEntry] : nil)
        let cb = onCursor
        // async: submits run inside SwiftUI view updates — never mutate state mid-update
        DispatchQueue.main.async { cb?(c, p) }
    }

    // ── touch: drag pans BOTH axes (the canvas owns the gesture, same job as Android's
    // requestDisallowInterceptTouchEvent — the page scroller can't steal vertical drags),
    // tap = cursor + tune, long-press = ★ toggle ──
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        shiftPx = min(max(0, shiftPx - t.x), maxShift)
        scrollYpx = min(max(0, scrollYpx - t.y), maxScrollY)
        setNeedsDisplay()
    }
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        tapAt(p.x, p.y, tune: true)
    }
    @objc private func onLong(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        guard tapAt(p.x, p.y, tune: false),
              rows.indices.contains(curRow), let c = rows[curRow].channel else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onFav?(c, !favs.contains(c.id))
    }

    /// Map a touch point to the cursor (row + entry); optionally tune. false = header/gap band.
    @discardableResult
    private func tapAt(_ x: CGFloat, _ y: CGFloat, tune: Bool) -> Bool {
        guard y >= rulerH, !rows.isEmpty else { return false }
        let cy = y - rulerH + scrollYpx
        guard let found = rows.indices.first(where: { cy >= rowY[$0] && cy < rowY[$0 + 1] }),
              let c = rows[found].channel else { return false }
        curRow = found; cursorChannel = c.id
        inChannelCol = x < chColW
        if !inChannelCol {
            let t = viewLeftMs() + Int((x - chColW) / pxPerMin * 60_000)
            curEntry = entryAtTime(c, t)
        }
        notifyCursor()
        setNeedsDisplay()
        if tune, let ch = rows[curRow].channel { onTune?(ch) }
        return true
    }

    // ── logos: async decode → cache → setNeedsDisplay (Android logoFor) ──
    private var logos: [String: UIImage] = [:]
    private var logoPending = Set<String>()
    private func logoFor(_ c: LiveChannel) -> UIImage? {
        if let img = logos[c.id] { return img }
        guard !logoPending.contains(c.id), !c.logo.isEmpty, let u = URL(string: c.logo) else { return nil }
        logoPending.insert(c.id)
        if logos.count > 400 { logos.removeAll() }
        Task { [weak self] in
            guard let d = try? await URLSession.shared.data(from: u).0, let img = UIImage(data: d) else { return }
            await MainActor.run {
                guard let self else { return }
                self.logos[c.id] = img
                self.setNeedsDisplay()
            }
        }
        return nil
    }

    // ── text: single line, tail-truncated, inside a rect ──
    private func drawText(_ s: String, in rect: CGRect, font: UIFont, color: UIColor) {
        guard rect.width > 4 else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(with: rect,
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para],
                             context: nil)
    }

    // ── draw (the whole guide, every frame, visible rows only) ──
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !rows.isEmpty else { return }
        let now = LiveTV.nowMs()
        let w = bounds.width, h = bounds.height
        let cellLive = ckBlend(cellBase, accent, 0.20)
        // 🔴 live-sports rows read RED, not accent — "so they know this is live now" (AJ Nov 7)
        let cellLiveRed = ckBlend(cellBase, redCol, 0.30)
        let cellFocus = ckBlend(cellBase, accent, 0.60)
        let focusStroke = ckBlend(accent, .white, 0.45)
        ctx.setFillColor(bgCol.cgColor); ctx.fill(bounds)

        // ── ruler: date cell (tracks the pan across midnight) + 30-min ticks ──
        ctx.setFillColor(secBgCol.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: chColW, height: rulerH))
        let leftMs = viewLeftMs()
        drawText(Self.dayFmt.string(from: Date(timeIntervalSince1970: Double(leftMs) / 1000)),
                 in: CGRect(x: 8, y: 6, width: chColW - 12, height: 14), font: rulerFont, color: fgCol)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: chColW, y: 0, width: w - chColW, height: rulerH))
        var tick = dayStart - dayStart % 1_800_000
        while tick < winEnd {
            let x = xOfTime(tick)
            if x > w { break }
            if x + 80 > chColW {
                drawText(Self.clock(tick), in: CGRect(x: x + 4, y: 7, width: 76, height: 13),
                         font: rulerFont, color: dimCol)
            }
            tick += 1_800_000
        }
        ctx.restoreGState()

        // ── rows (visible window only) ──
        let viewTop = scrollYpx, viewBot = scrollYpx + (h - rulerH)
        var i = rows.indices.first(where: { rowY[$0 + 1] > viewTop }) ?? 0
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: rulerH, width: w, height: h - rulerH))
        while i < rows.count && rowY[i] < viewBot {
            let y0 = rowY[i] - scrollYpx + rulerH
            let row = rows[i]
            if let hdr = row.header {   // section header band (🔴 live sections draw RED)
                ctx.setFillColor(secBgCol.cgColor)
                ctx.fill(CGRect(x: 0, y: y0, width: w, height: hdrRowH - 2))
                drawText(hdr.uppercased(), in: CGRect(x: 8, y: y0 + 6, width: w - 16, height: 13),
                         font: secFont, color: hdr.hasPrefix("🔴") ? redCol : secCol)
                i += 1; continue
            }
            guard let c = row.channel else { i += 1; continue }
            let focusRow = i == curRow
            // channel cell
            let chRect = CGRect(x: 1, y: y0, width: chColW - 3, height: rowH)
            let chPath = UIBezierPath(roundedRect: chRect, cornerRadius: 6)
            (focusRow && inChannelCol ? cellFocus : chColBg).setFill()
            chPath.fill()
            if focusRow && inChannelCol {
                focusStroke.setStroke(); chPath.lineWidth = 2; chPath.stroke()
            }
            var tx: CGFloat = 7
            if let bm = logoFor(c) {
                bm.draw(in: CGRect(x: tx, y: y0 + (rowH - 24) / 2, width: 24, height: 24))
            }
            if !c.logo.isEmpty { tx += 30 }
            let nm = (favs.contains(c.id) ? "★ " : "") + row.display
            drawText(nm, in: CGRect(x: tx, y: y0 + rowH / 2 - 8, width: chColW - tx - 6, height: 16),
                     font: chFont, color: fgCol)
            // programme cells (clipped to the lane)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: chColW, y: rulerH, width: w - chColW, height: h - rulerH))
            let red = redRow.indices.contains(i) && redRow[i]
            if c.progs.isEmpty {
                // gap-as-entry: a channel with no listings gets ONE full-span filler cell
                drawCell(x0: xOfTime(dayStart), x1: xOfTime(winEnd), y0: y0, title: "Live programming",
                         startMs: dayStart, live: red, past: false,
                         focused: focusRow && !inChannelCol, showTime: false, red: red,
                         cellLive: cellLive, cellLiveRed: cellLiveRed, cellFocus: cellFocus, focusStroke: focusStroke)
            } else {
                for (pi, p) in c.progs.enumerated() {
                    if p.e <= dayStart || p.s >= winEnd { continue }
                    let x0 = xOfTime(max(p.s, dayStart))
                    let x1 = xOfTime(min(p.e, winEnd))
                    if x1 < chColW { continue }
                    if x0 > w { break }
                    drawCell(x0: x0, x1: x1, y0: y0, title: p.t, startMs: p.s,
                             live: p.s <= now && p.e > now, past: p.e <= now,
                             focused: focusRow && !inChannelCol && pi == curEntry, showTime: true, red: red,
                             cellLive: cellLive, cellLiveRed: cellLiveRed, cellFocus: cellFocus, focusStroke: focusStroke)
                }
            }
            ctx.restoreGState()
            i += 1
        }
        ctx.restoreGState()

        // ── now line across the grid ──
        let nowX = xOfTime(now)
        if nowX >= chColW && nowX <= w {
            ctx.setFillColor(nowLineCol.cgColor)
            ctx.fill(CGRect(x: nowX, y: rulerH, width: 2, height: h - rulerH))
        }
    }

    private func drawCell(x0: CGFloat, x1: CGFloat, y0: CGFloat, title: String, startMs: Int,
                          live: Bool, past: Bool, focused: Bool, showTime: Bool, red: Bool,
                          cellLive: UIColor, cellLiveRed: UIColor, cellFocus: UIColor, focusStroke: UIColor) {
        let l = x0 + 1, r = x1 - 1
        guard r - l >= 3 else { return }
        let rect = CGRect(x: l, y: y0, width: r - l, height: rowH)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        let fill: UIColor = focused ? cellFocus : live ? (red ? cellLiveRed : cellLive) : past ? cellPast : cellBase
        fill.setFill(); path.fill()
        (focused ? focusStroke : cellLine).setStroke()
        path.lineWidth = focused ? 2 : 1
        path.stroke()
        guard r - l >= 52 else { return }
        // LABEL PINNING (Kodi): text starts at the viewport edge while the cell hangs off-left
        let textL = max(l, chColW) + 6
        let avail = r - textL - 6
        guard avail >= 30 else { return }
        drawText(title, in: CGRect(x: textL, y: y0 + 9, width: avail, height: 15),
                 font: titleFont, color: focused || live ? fgCol : past ? pastTxt : dimCol)
        if showTime {
            drawText(Self.clock(startMs), in: CGRect(x: textL, y: y0 + 27, width: avail, height: 13),
                     font: timeFont, color: past ? pastTxt : timeCol)
        }
    }
}

/// SwiftUI bridge: resubmits only when the model signature moves (cursor preserved by channel
/// id); every other update is just a repaint so the now-line/live tints track the 60s clock.
struct GuideCanvasRep: UIViewRepresentable {
    let model: CKGuideModel
    let now: Int
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel, Bool) -> Void
    let onCursor: (LiveChannel, LiveProg?) -> Void

    func makeUIView(context: Context) -> GuideCanvasUIView {
        let v = GuideCanvasUIView()
        wire(v)
        v.accent = UIColor(Theme.accent)
        v.submit(model)
        return v
    }
    func updateUIView(_ v: GuideCanvasUIView, context: Context) {
        wire(v)   // fresh closures every update — no stale captured state
        let a = UIColor(Theme.accent)   // per-profile accent can change while the view lives
        if a != v.accent { v.accent = a }
        if v.modelSig != model.sig { v.submit(model) }
        v.setNeedsDisplay()   // `now` tick: now-line + live tints realign, zero rebuild
    }
    private func wire(_ v: GuideCanvasUIView) {
        v.onTune = onTune
        v.onFav = onFav
        v.onCursor = onCursor
    }
}

// MARK: - the guide view (detail card + 🔴 sections loop + canvas)

/// The shared guide v3 surface: detail card pinned above the drawn grid. Hosts: the Live TV
/// page (GuideV3Panel) and the live player's corner-player overlay (cornerReserve > .zero
/// keeps the top band clear of the shrunk video).
struct GuideCanvasView: View {
    @EnvironmentObject var session: Session
    let guide: LiveGuide
    let dayStart: Int
    let winEnd: Int
    let now: Int
    var cornerReserve: CGSize = .zero     // corner-player overlay: space for the video top-right
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void      // host patches favs + resubmits (instant ★ re-sort)

    // 🔴 per-sport LIVE sections (games.json, 60s refresh, sig-gated — finished games fall off)
    @State private var topRows: [CKGuideRow] = []
    @State private var topSig = ""
    // detail-card cursor + lazy description (epgdesc.json, 250ms debounce, per-channel cache)
    @State private var selCh: LiveChannel?
    @State private var selProg: LiveProg?
    @State private var selDesc = ""

    private var model: CKGuideModel {
        CKGuideModel.build(guide: guide, top: topRows, dayStart: dayStart, winEnd: winEnd)
    }
    private var descKey: String { (selCh?.id ?? "") + ":" + String(selProg?.s ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if cornerReserve == .zero {
                detailCard
            } else {
                // corner-player overlay: detail card left, the punched video hole right
                HStack(alignment: .top, spacing: 12) {
                    detailCard
                    Color.clear.frame(width: cornerReserve.width)
                }
                .frame(minHeight: cornerReserve.height, alignment: .top)
            }
            GuideCanvasRep(model: model, now: now,
                           onTune: { ch in onTune(ch) },
                           onFav: { ch, _ in onFav(ch) },
                           onCursor: { ch, p in
                               if ch.id != selCh?.id || p?.s != selProg?.s { selDesc = "" }
                               selCh = ch; selProg = p
                           })
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        // restart the 🔴 loop whenever a fresh guide lands (its `at` stamp moves) so the loop
        // never maps games onto a stale channel list
        .task(id: "\(guide.at)|\(guide.channels.count)") {
            await refreshTop()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await refreshTop()
            }
        }
        .task(id: descKey) { await loadDesc() }
    }

    /// FIXED height so cursor moves never shift the grid (Android dcCard, 92dp).
    private var detailCard: some View {
        let live = selProg.map { $0.s <= now && now < $0.e } ?? false
        let frac: Double = {
            guard let p = selProg, live, p.e > p.s else { return 0 }
            return min(1, max(0, Double(now - p.s) / Double(p.e - p.s)))
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                if let lg = selCh?.logo, !lg.isEmpty {
                    AsyncImage(url: URL(string: lg)) { img in img.resizable().aspectRatio(contentMode: .fit) }
                        placeholder: { Color.clear }
                        .frame(width: 22, height: 22)
                }
                Text(chanLine).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                if live {   // accent progress through the airing programme
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.card2)
                        Capsule().fill(Theme.accent).frame(width: 120 * frac)
                    }
                    .frame(width: 120, height: 3)
                }
                Spacer(minLength: 0)
            }
            Text(selProg?.t ?? (selCh == nil ? " " : "Live programming"))
                .font(.system(size: 16.5, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            Text(selDesc).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
        .background(Color(red: 0x17 / 255.0, green: 0x13 / 255.0, blue: 0x2B / 255.0),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var chanLine: String {
        let name = selCh.map { ckCleanChannelName($0.name) } ?? ""
        guard let p = selProg else { return name }
        return name + "   \(LiveTV.clock(p.s)) – \(LiveTV.clock(p.e))"
    }

    /// Android refreshTopSections: only games CURRENTLY live, one row per channel, under a red
    /// "🔴 <emoji> <SPORT> — LIVE" header; sig-gated so the grid only resubmits on change.
    /// (NO upcoming games inside the guide — AJ Nov 7 "no no no"; the 📅 chip owns those.)
    private func refreshTop() async {
        let sports = await LiveTV.games(session)
        var byId: [String: LiveChannel] = [:]
        for c in guide.channels where byId[c.id] == nil { byId[c.id] = c }
        var rows: [CKGuideRow] = []
        var seen = Set<String>()
        for sp in sports where !sp.live.isEmpty {
            var sec: [CKGuideRow] = []
            for g in sp.live {
                let cid = g.chid.replacingOccurrences(of: "cklive:", with: "")
                guard let ch = byId[cid], seen.insert(cid).inserted else { continue }
                sec.append(CKGuideRow(channel: ch))
            }
            if !sec.isEmpty {
                rows.append(CKGuideRow(header: "🔴 \(sp.emoji) \(sp.sport.uppercased()) — LIVE"))
                rows += sec
            }
        }
        let sig = rows.map { $0.header ?? ($0.channel?.id ?? "") }.joined(separator: "|")
        if sig != topSig { topSig = sig; topRows = rows }
    }

    /// 250ms debounce (task(id:) cancellation is the debounce), per-channel cache in LiveTV.
    private func loadDesc() async {
        guard let ch = selCh, let p = selProg else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let progs = await LiveTV.epgDesc(session, ch: ch.id)
        guard !Task.isCancelled, selCh?.id == ch.id, selProg?.s == p.s else { return }
        if let q = progs.first(where: { StateMerge.stamp($0["s"]) == p.s }) {
            selDesc = q["d"] as? String ?? ""
        }
    }
}

// MARK: - the Live TV page panel (day tabs + ↻ recent + the canvas)

/// The page viewport height — the canvas sizes itself to the real remaining screen (Android
/// sizeToViewport) instead of a guessed constant.
struct CKGuideHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 700 }
extension EnvironmentValues {
    var ckGuideHeight: CGFloat {
        get { self[CKGuideHeightKey.self] }
        set { self[CKGuideHeightKey.self] = newValue }
    }
}

/// Drop-in replacement for GuideGrid on the phone Live TV page: day tabs + ↻ Continue watching
/// strip (both kept from the classic guide), then the detail card + canvas.
struct GuideV3Panel: View {
    @EnvironmentObject var session: Session
    let guide: LiveGuide
    @Binding var day: Int
    let now: Int
    let onTune: (LiveChannel) -> Void
    let onFav: (LiveChannel) -> Void
    @Environment(\.ckGuideHeight) private var pageH

    private var dayStart: Int { LiveTV.dayStart(day, now: now) }
    private var winEnd: Int { dayStart + (day == 0 ? 72 : 24) * 3_600_000 }
    private var recent: [LiveChannel] {
        guide.recent.compactMap { id in (guide.channels + guide.favChannels).first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dayTabs
            if !recent.isEmpty && day == 0 { recentStrip }
            if guide.channels.isEmpty {
                Text("No guide right now — pull to refresh.").foregroundStyle(.secondary).padding(24)
            } else {
                GuideCanvasView(guide: guide, dayStart: dayStart, winEnd: winEnd, now: now,
                                onTune: onTune, onFav: onFav)
                    // the canvas owns vertical scrolling inside this slot; day tabs + detail
                    // card + banner chrome above eat the rest of the page
                    .frame(height: max(380, pageH - 230))
            }
        }
        .padding(.horizontal, Platform.gutter)
    }

    private var dayTabs: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { d in
                Button(LiveTV.dayLabel(d, now: now)) { day = d }
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(day == d ? Theme.panel : .clear, in: Capsule())
                    .overlay(Capsule().stroke(day == d ? Theme.accent : Theme.card, lineWidth: 1))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("↻ Continue watching").font(.caption.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(recent) { ch in
                        Button { onTune(ch) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ckCleanChannelName(ch.name)).font(.caption.bold()).lineLimit(1)
                                Text(ch.now(now)?.t ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(8).frame(width: 150, alignment: .leading)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }
}

/// 97%-opaque scrim with an even-odd PUNCHED HOLE where the corner video sits (the IPVIO
/// pattern Android's showFullGuide uses) — the shrunk AVPlayerLayer shows through untouched.
struct PunchedScrim: View {
    let hole: CGRect
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10))
            }
            .fill(Color(red: 0x09 / 255.0, green: 0x0B / 255.0, blue: 0x12 / 255.0).opacity(0.97),
                  style: FillStyle(eoFill: true))
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // swallow taps so the player's show/hide-controls catcher can't fire
    }
}
#endif
