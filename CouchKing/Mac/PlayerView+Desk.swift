#if os(macOS)
import SwiftUI
import AVKit
import AppKit

// The desktop player chrome (reference/desktop ck-web.js webPlay() + style.css 211-277):
// in-window black overlay; top gradient bar "‹ Back" · title · clock / "Ends h:mm"; bottom
// gradient: 6px purple scrubber with a 14px white knob (click to seek), times row, then a
// centered row of #241F3DCC buttons each with a small muted label ABOVE it:
// Back 10s · Play/Pause · Forward 10s · [Next] · Subtitles · Sub Size · Size · Speed · Info ·
// Volume · Fullscreen. Mouse idle 3s (while playing) fades the UI over .25s. Click the video =
// play/pause. Keys: Space, ←, →, Esc only. Skip pill bottom-left and Up Next card bottom-right
// at 170px. No PiP / AirPlay / audio menu (the desktop has none).
extension PlayerView {
    var deskOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                deskTop
                Spacer()
                deskBottom
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)

            if !currentCue.isEmpty {
                VStack { Spacer()
                    SubtitleText(text: currentCue).frame(maxWidth: 900)
                        .padding(.bottom, deskCueBottom)
                }
                .allowsHitTesting(false)
            }
            // skip pill — left 2rem, bottom 170px
            if !placeholder, let st = skipState {
                VStack { Spacer()
                    HStack {
                        DeskPill(text: deskSkipLabel(st.0)) {
                            epTouched = true
                            if st.0 == "Skip Recap" { recapHandled = true }
                            if st.0 == "Skip Intro" { introHandled = true }
                            seek(ms: st.1)
                        }
                        Spacer()
                    }
                    .padding(.leading, 32).padding(.bottom, 170)
                }
            }
            if speedMenu { deskSpeedMenu }
            if showSubPanel { deskSubPanel }
            if showStats { deskInfoBox }
            if !flash.isEmpty || !toast.isEmpty {
                VStack { Spacer()
                    Text(flash.isEmpty ? toast : flash).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 19.2).padding(.vertical, 9.6)
                        .background(Desk.card2.opacity(0xF2 / 255.0), in: Capsule())
                        .padding(.bottom, 220)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var deskCueBottom: CGFloat {
        switch session.pref("subPos", "normal") {
        case "high": return 1080 * 0.24
        case "raised": return 1080 * 0.16
        default: return 1080 * 0.09
        }
    }

    private func deskSkipLabel(_ s: String) -> String {
        switch s {
        case "Skip Intro": return "Skip intro ⏭"
        case "Skip Recap": return "Skip recap ⏭"
        default: return s
        }
    }

    // MARK: top bar (.wp-top)
    private var deskTop: some View {
        HStack(alignment: .top, spacing: 16) {
            Button("‹ Back") { close() }.buttonStyle(DeskPlayerButton())
            Text(titleLine).font(.system(size: 16.8, weight: .heavy)).foregroundStyle(.white)
                .shadow(color: .black, radius: 3, y: 1).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                if isLive {
                    Text("🔴 LIVE").font(.system(size: 16, weight: .bold)).foregroundStyle(Desk.hex(0xFF5B5B))
                }
                Text(Date.now, format: .dateTime.hour().minute()).font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                if durMs > 1000 && !isLive && !placeholder {
                    Text(endsText).font(.system(size: 12.8, weight: .bold)).foregroundStyle(Desk.text2)
                }
            }
        }
        .padding(.horizontal, 19.2).padding(.vertical, 16)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var titleLine: String {
        if let s = request.season, let e = request.episode {
            return "\(request.meta.name) — S\(s) · E\(e)"
        }
        return request.meta.name
    }

    // MARK: bottom (.wp-bottom)
    private var deskBottom: some View {
        VStack(spacing: 0) {
            if !isLive && !placeholder && durMs > 0 {
                deskScrubber.padding(.bottom, 6.4)
                HStack {
                    Text(clock(posMs)); Spacer(); Text(durMs > 0 ? clock(durMs) : "–:––")
                }
                .font(.system(size: 13.6, weight: .bold)).foregroundStyle(Desk.text2)
                .padding(.bottom, 8)
            }
            HStack(alignment: .bottom, spacing: 25.6) {
                if !isLive && !placeholder {
                    let step = session.pref("seekStep", 10)
                    deskCell("Back \(step)s") { Button("⏪") { epTouched = true; remoteSeek(-1) } }
                }
                deskCell("Play / Pause") { Button(playing ? "⏸" : "▶") { togglePlay() } }
                if !isLive && !placeholder {
                    let step = session.pref("seekStep", 10)
                    deskCell("Forward \(step)s") { Button("⏩") { epTouched = true; remoteSeek(1) } }
                }
                if request.season != nil, let ep = nextEp {
                    deskCell("Next") { Button("⏭") { epTouched = true; Task { await playEpisode(ep, idle: 0) } } }
                }
                if !isLive {
                    deskCell("Subtitles") {
                        Button("💬") { showSubPanel.toggle(); speedMenu = false }
                            .buttonStyle(DeskPlayerButton(on: subIndex >= 0))
                    }
                    deskCell("Sub Size") { Button("Aa") { cycleSubSize() } }
                    deskCell("Size") { Button("⤢") { cycleDeskSize() } }
                    deskCell("Speed") {
                        Button(rate == 1 ? "1×" : String(format: "%g×", rate)) { speedMenu.toggle(); showSubPanel = false }
                    }
                    deskCell("Info") { Button("ⓘ") { showStats.toggle() }.buttonStyle(DeskPlayerButton(on: showStats)) }
                }
                deskCell("Volume") {
                    Slider(value: Binding(get: { volume }, set: { volume = $0; player.volume = Float($0) }),
                           in: 0...1, step: 0.05)
                        .frame(width: 110).tint(Desk.accent)
                }
                deskCell("Fullscreen") { Button("⛶") { NSApp.keyWindow?.toggleFullScreen(nil) } }
            }
            .buttonStyle(DeskPlayerButton())
        }
        .padding(.horizontal, 22.4).padding(.bottom, 16).padding(.top, 40)
        .background(LinearGradient(colors: [.black.opacity(0.87), .clear], startPoint: .bottom, endPoint: .top))
    }

    /// `.wp-cell`: muted .72rem/700 label ABOVE the control.
    private func deskCell<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(spacing: 4.8) {
            Text(label).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Desk.muted)
            control()
        }
    }

    /// `.wp-bar` 6px #FFFFFF3A pill, accent fill, 14px white knob; click to seek (no drag).
    private var deskScrubber: some View {
        GeometryReader { g in
            let frac = CGFloat(Double(posMs) / Double(max(durMs, 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0x3A / 255.0)).frame(height: 6)
                Capsule().fill(Desk.accent).frame(width: max(0, g.size.width * frac), height: 6)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.67), radius: 3)
                    .offset(x: max(0, g.size.width * frac - 7))
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                epTouched = true
                seek(ms: Int(Double(p.x / max(1, g.size.width)) * Double(durMs)))
                scheduleHide()
            }
        }
        .frame(height: 14)
    }

    /// Sub Size cycles Small → Normal → Large → Huge (label flashes 1200ms).
    private func cycleSubSize() {
        let steps: [(Double, String)] = [(0.8, "Small"), (1.0, "Normal"), (1.3, "Large"), (1.6, "Huge")]
        let cur = session.pref("subScale", 1.0)
        let i = steps.firstIndex { $0.0 == cur } ?? 1
        let n = steps[(i + 1) % steps.count]
        session.setPref("subScale", n.0)
        flashLabel("Subtitles: \(n.1)")
    }

    /// Size cycles Fit (contain) → Fill (cover) → Stretch (fill) — stored in the shared scaleMode
    /// pref as fit / zoom / fill.
    private func cycleDeskSize() {
        let order: [(String, String)] = [("fit", "Fit"), ("zoom", "Fill"), ("fill", "Stretch")]
        let i = order.firstIndex { $0.0 == scaleMode } ?? 0
        let n = order[(i + 1) % order.count]
        scaleMode = n.0
        session.setPref("scaleMode", n.0)
        flashLabel("Size: \(n.1)")
    }

    // MARK: menus / panels
    /// `.wp-menu` Speed: centered above the bar; current = accent + "   ✓"; closes on pick.
    private var deskSpeedMenu: some View {
        VStack { Spacer()
            DeskMenuCard(title: "Speed", width: 230) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                    DeskMenuItem(text: r == 1 ? "Normal" : String(format: "%g×", r), on: rate == Float(r)) {
                        setRate(Float(r)); speedMenu = false
                    }
                }
            }
            .padding(.bottom, 150)
        }
    }

    /// `.wp-subpanel`: pinned to the right edge, 280px, stays open while picking.
    private var deskSubPanel: some View {
        HStack { Spacer()
            DeskMenuCard(title: "Subtitles", width: 280, rightEdge: true) {
                DeskMenuItem(text: "Subtitles off", on: subIndex < 0) { pickSub(-1) }
                ForEach(subTracks.indices, id: \.self) { i in
                    let t = subTracks[i]
                    DeskMenuItem(text: t["name"] as? String ?? t["lang"] as? String ?? "Track \(i + 1)", on: subIndex == i) { pickSub(i) }
                }
            }
        }
    }

    /// `.wp-infobox` top 76 / right 1.2rem.
    private var deskInfoBox: some View {
        VStack { HStack { Spacer()
            Text(stats.isEmpty ? "—" : stats).font(.system(size: 13.6, weight: .bold)).foregroundStyle(Desk.text2)
                .padding(.horizontal, 16).padding(.vertical, 12.8)
                .background(Desk.hex(0x16132A, 0xDD / 255.0), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Desk.border, lineWidth: 1))
        }; Spacer() }
        .padding(.top, 76).padding(.trailing, 19.2)
        .allowsHitTesting(false)
    }

    /// `.wp-next` Up Next card — right 2rem, bottom 170px.
    func deskNextUp(_ ep: Episode) -> some View {
        VStack { Spacer()
            HStack { Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    Text("UP NEXT").font(.system(size: 11.5, weight: .black)).tracking(1.2).foregroundStyle(Desk.muted)
                    Text("\(request.meta.name) S\(ep.season)E\(ep.episode) — \(ep.name)")
                        .font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                        .padding(.top, 4.8).padding(.bottom, 11.2)
                    HStack(spacing: 8) {
                        Button("▶ Play now") { epTouched = true; showNextUp = false; Task { await playEpisode(ep, idle: 0) } }
                            .buttonStyle(DeskButton(kind: .primary, small: true))
                        Button("Dismiss") { epTouched = true; showNextUp = false; nextUpDismissed = true }
                            .buttonStyle(DeskButton(kind: .ghost, small: true))
                    }
                }
                .padding(.horizontal, 19.2).padding(.vertical, 16)
                .frame(maxWidth: 340, alignment: .leading)
                .background(Desk.hex(0x16132A, 0xF0 / 255.0), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Desk.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.8), radius: 13, y: 6)
            }
            .padding(.trailing, 32).padding(.bottom, 170)
        }
    }

    /// "Are you still watching?" — purple-glow card on a rgba(8,6,20,.88) scrim.
    var deskStillWatching: some View {
        ZStack {
            Color(.sRGB, red: 8 / 255, green: 6 / 255, blue: 20 / 255, opacity: 0.88).ignoresSafeArea()
            VStack(spacing: 10) {
                Text("👑").font(.system(size: 36.8))
                Text("Are you still watching?").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text(request.meta.name).font(.system(size: 15.2)).foregroundStyle(Desk.muted)
                Button("Keep watching") {
                    showStillWatching = false
                    if let ep = nextEp { Task { await playEpisode(ep, idle: 0) } } else { close() }
                }
                .buttonStyle(DeskPillButton(fill: Desk.accent))
                .keyboardShortcut(.defaultAction)
                Button("I'm done for now") { close() }.buttonStyle(DeskPillButton(fill: Desk.hex(0x2C2649)))
                Text("No answer in 5 minutes and we'll tuck the stream in for the night 😴")
                    .font(.system(size: 12.8)).foregroundStyle(Desk.hex(0x6A6590)).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
            .frame(maxWidth: 380)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Desk.hex(0x2C2649), lineWidth: 1))
            .shadow(color: Desk.accent.opacity(0.28), radius: 30, y: 12)
        }
    }

    /// Desktop keys: Space = play/pause, ← / → = seek step, Esc = exit full screen, else close.
    var deskKeys: some View {
        ZStack {
            Button("") { togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { epTouched = true; remoteSeek(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { epTouched = true; remoteSeek(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") {
                if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                else { close() }
            }
            .keyboardShortcut(.cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// `.wp-btn`: #241F3DCC, white 1.25rem, padding .55rem 1rem, r12; hover / `.on` = accent.
struct DeskPlayerButton: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hover in
            configuration.label
                .font(.system(size: 20)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8.8)
                .background(hover || on ? Desk.accent : Desk.card2.opacity(0xCC / 255.0), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// `.wp-skip`: #241F3DE6, 1px #FFFFFF3A, white 800 1rem, pill, hover = accent.
struct DeskPill: View {
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 20.8).padding(.vertical, 11.2)
                .background(hover ? Desk.accent : Desk.card2.opacity(0xE6 / 255.0), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0x3A / 255.0), lineWidth: 1))
                .shadow(color: .black.opacity(0.67), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Full-width pill button (still-watching dialog).
struct DeskPillButton: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// `.wp-menu` card: #1B1830, 1px #37315C, r16, uppercase muted title.
struct DeskMenuCard<Content: View>: View {
    let title: String
    let width: CGFloat
    var rightEdge = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3.2) {
            Text(title.uppercased()).font(.system(size: 11.5, weight: .heavy)).tracking(0.9).foregroundStyle(Desk.muted)
                .padding(.horizontal, 14.4).padding(.top, 3.2).padding(.bottom, 8)
            ScrollView { VStack(alignment: .leading, spacing: 3.2) { content() } }
                .frame(maxHeight: 520)
        }
        .padding(11.2)
        .frame(width: width)
        .background(Desk.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Desk.border, lineWidth: 1))
        .padding(.trailing, rightEdge ? -16 : 0)   // right-edge panel: flush, corners off-screen
        .shadow(color: .black.opacity(0.8), radius: 20, y: 12)
    }
}

struct DeskMenuItem: View {
    let text: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(on ? text + "   ✓" : text)
                .font(.system(size: 15.2, weight: on ? .heavy : .regular))
                .foregroundStyle(on ? Desk.accent : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14.4).padding(.vertical, 8.8)
                .background(hover ? Desk.menuHover : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
#endif
