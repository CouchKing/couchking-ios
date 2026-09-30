#if os(tvOS)
import SwiftUI
import AVKit

// The Firestick player (reference/android-tv PlayerActivity.kt + ck_controls.xml + styles.xml),
// 1dp = 2pt: top overlay (‹ 42dp · title 19sp · clock 18sp bold / "Ends" 14sp #BBBBCC) · center
// play/pause (CKCenterBtn 72dp, no caption) · bottom: position · purple time bar · duration, and a
// row of CKCell buttons (10sp caption ABOVE a 52dp icon): Next · Episodes · Subtitles · Sub Size ·
// Size · Audio · Speed · Info (movies hide Next/Episodes; live: Favorite · Guide, no Speed).
// Remote: hidden → OK toggles play/pause, any arrow shows the controls with focus on the time bar;
// on the time bar ←/→ seek by the seek step. Controls auto-hide after 5s. Menu peels one layer.
extension PlayerView {
    var tvOverlay: some View {
        ZStack {
            if controlsVisible {
                VStack(spacing: 0) {
                    tvTop
                    Spacer()
                    tvBottom
                }
                .transition(.opacity)
                // CKCenterBtn: play/pause only on TV
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: TV.dp(26)))
                        .foregroundStyle(.white).frame(width: TV.dp(72), height: TV.dp(72))
                }
                .buttonStyle(TVRingButton(radius: TV.dp(36)))
                .focused($pfocus, equals: .play)
            }
            if !currentCue.isEmpty {
                VStack { Spacer()
                    SubtitleText(text: currentCue).frame(maxWidth: 1400)
                        .padding(.bottom, 1080 * tvCueFraction)
                }
                .allowsHitTesting(false)
            }
            if !placeholder, let st = skipState { tvSkipPill(st) }
            if !flash.isEmpty { tvFlash }
            if showStats {
                VStack { HStack {
                    Text(stats).font(.system(size: TV.sp(14), design: .monospaced)).foregroundStyle(TV.rgb(0xDDDDEE))
                        .padding(TV.dp(12)).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: TV.dp(8)))
                    Spacer() }; Spacer() }
                    .padding(TV.dp(24)).allowsHitTesting(false)
            }
            if showSubPanel { tvCaptions }
            if showEpisodes && !request.episodes.isEmpty { tvEpisodeDrawer }
            if speedMenu { tvSpeedSheet }
            if audioMenu { tvAudioSheet }
        }
        .animation(.easeOut(duration: 0.22), value: controlsVisible)
    }

    private var tvCueFraction: CGFloat {
        switch session.pref("subPos", "normal") {
        case "high": return 0.26
        case "raised": return 0.16
        default: return 0.08
        }
    }

    /// Menu/BACK — one layer per press: captions panel → sheets → next-up → episode drawer →
    /// controller → exit.
    func tvBack() {
        if showSubPanel { showSubPanel = false; showControls(); return }
        if speedMenu || audioMenu { speedMenu = false; audioMenu = false; showControls(); return }
        if showNextUp { showNextUp = false; nextUpDismissed = true; return }
        if showEpisodes { showEpisodes = false; showControls(); return }
        if controlsVisible { hideTask?.cancel(); controlsVisible = false; pfocus = .picture; return }
        close()
    }

    // MARK: top (padding 24dp, top scrim)
    private var tvTop: some View {
        HStack(alignment: .top, spacing: TV.dp(10)) {
            Button { close() } label: {
                Text("‹").font(.system(size: TV.sp(26))).foregroundStyle(.white)
                    .frame(width: TV.dp(42), height: TV.dp(42))
            }
            .buttonStyle(TVRingButton(radius: TV.dp(21)))
            Text(tvTitle).font(.system(size: TV.sp(19))).foregroundStyle(.white).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Date.now, format: .dateTime.hour().minute()).font(.system(size: TV.sp(18), weight: .bold)).foregroundStyle(.white)
                if durMs > 1000 && !isLive && !placeholder {
                    Text(endsText).font(.system(size: TV.sp(14))).foregroundStyle(TV.captionGrey)
                }
            }
        }
        .padding(TV.dp(24))
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
        .focusSection()
    }

    private var tvTitle: String {
        if let s = request.season, let e = request.episode { return "\(request.meta.name) · S\(s) E\(e)" }
        return request.meta.name
    }

    // MARK: bottom (seek row + CKCell buttons row)
    private var tvBottom: some View {
        VStack(spacing: TV.dp(6)) {
            if isLive {
                Text("🔴 LIVE").font(.system(size: TV.sp(14), weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, TV.dp(24))
            } else if !placeholder && durMs > 0 {
                HStack(spacing: TV.dp(8)) {
                    Text(clock(posMs)).font(.system(size: TV.sp(14))).foregroundStyle(.white)
                    TVTimeBar(pos: posMs, dur: durMs, buffered: bufferedMs)
                        .focusable()
                        .focused($pfocus, equals: .seek)
                        .onMoveCommand { dir in
                            epTouched = true
                            switch dir {
                            case .left: remoteSeek(-1); scheduleHide()
                            case .right: remoteSeek(1); scheduleHide()
                            case .up: pfocus = .play
                            default: pfocus = .ctrl(firstControl)
                            }
                        }
                        .onTapGesture { togglePlay() }
                    Text(clock(durMs)).font(.system(size: TV.sp(14))).foregroundStyle(TV.captionGrey)
                }
                .padding(.horizontal, TV.dp(24))
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(tvControls, id: \.id) { c in
                    VStack(spacing: -TV.dp(8)) {
                        Text(c.caption).font(.system(size: TV.sp(10))).foregroundStyle(.white)
                            .shadow(color: .black, radius: TV.dp(4))
                            .zIndex(1)
                        Button(action: c.action) {
                            Image(systemName: c.icon).font(.system(size: TV.dp(20)))
                                .foregroundStyle(c.tint).frame(width: TV.dp(52), height: TV.dp(52))
                        }
                        .buttonStyle(TVRingButton(radius: TV.dp(12)))
                        .focused($pfocus, equals: .ctrl(c.id))
                    }
                    .padding(TV.dp(6))
                }
            }
            .padding(.bottom, TV.dp(16))
            .focusSection()
        }
        .padding(.top, TV.dp(40))
        .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top))
    }

    private var bufferedMs: Int {
        guard let r = player.currentItem?.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        return Int((r.start + r.duration).seconds * 1000)
    }

    struct TVControl { let id: String, caption: String, icon: String; var tint: Color = .white; let action: () -> Void }

    private var firstControl: String { tvControls.first?.id ?? "subs" }

    private var tvControls: [TVControl] {
        var out: [TVControl] = []
        if isLive {
            out.append(TVControl(id: "fav", caption: "Favorite", icon: liveFav ? "star.fill" : "star",
                                 tint: liveFav ? TV.favGold : .white) { toggleLiveFav() })
            return out
        }
        if request.season != nil {
            if let ep = nextEp {
                out.append(TVControl(id: "next", caption: "Next", icon: "forward.end.fill") {
                    epTouched = true; Task { await playEpisode(ep, idle: 0) } })
            }
            if !request.episodes.isEmpty {
                out.append(TVControl(id: "eps", caption: "Episodes", icon: "list.bullet.rectangle") {
                    showEpisodes = true; hideTask?.cancel() })
            }
        }
        out.append(TVControl(id: "subs", caption: "Subtitles", icon: "captions.bubble") { showSubPanel = true; hideTask?.cancel() })
        out.append(TVControl(id: "subsize", caption: "Sub Size", icon: "textformat.size") { cycleTVSubSize() })
        out.append(TVControl(id: "size", caption: "Size", icon: "aspectratio") { cycleTVSize() })
        if audioOpts.count > 1 {
            out.append(TVControl(id: "audio", caption: "Audio", icon: "waveform") { audioMenu = true; hideTask?.cancel() })
        }
        out.append(TVControl(id: "speed", caption: "Speed", icon: "speedometer") { speedMenu = true; hideTask?.cancel() })
        out.append(TVControl(id: "info", caption: "Info", icon: "info.circle") { showStats.toggle() })
        return out
    }

    private func toggleLiveFav() {
        let id = request.meta.id.replacingOccurrences(of: "cklive:", with: "")
        liveFav.toggle()
        let on = liveFav
        Task { _ = await LiveTV.setFav(session, id: id, on: on) }
        flashLabel(on ? "★ Added to Favorites" : "Removed from Favorites")
    }

    /// Sub Size cycles Normal → Large → Huge → Giant → Small → Tiny (flash pill).
    private func cycleTVSubSize() {
        let steps: [(Double, String)] = [(1.0, "Normal"), (1.3, "Large"), (1.6, "Huge"), (2.0, "Giant"), (0.8, "Small"), (0.6, "Tiny")]
        let cur = session.pref("subScale", 1.0)
        let i = steps.firstIndex { $0.0 == cur } ?? 0
        let n = steps[(i + 1) % steps.count]
        session.setPref("subScale", n.0)
        flashLabel(n.1)
    }

    /// Size cycles Fit → Fill (crop) → Stretch (shared scaleMode pref: fit / zoom / fill).
    private func cycleTVSize() {
        let order: [(String, String)] = [("fit", "Fit"), ("zoom", "Fill"), ("fill", "Stretch")]
        let i = order.firstIndex { $0.0 == scaleMode } ?? 0
        let n = order[(i + 1) % order.count]
        scaleMode = n.0
        session.setPref("scaleMode", n.0)
        flashLabel(n.1)
    }

    // MARK: skip pill (bottom-end, auto-focused, fades + rises in over 220ms)
    private func tvSkipPill(_ st: (String, Int)) -> some View {
        VStack { Spacer()
            HStack { Spacer()
                Button {
                    epTouched = true
                    if st.0 == "Skip Recap" { recapHandled = true }
                    if st.0 == "Skip Intro" { introHandled = true }
                    seek(ms: st.1)
                } label: {
                    Text(st.0 == "Skip Intro" ? "Skip Intro ⏭" : st.0 == "Skip Recap" ? "Skip Recap ⏭" : st.0)
                        .font(.system(size: TV.sp(14), weight: .bold)).foregroundStyle(TV.rgb(0x0C0C14))
                        .padding(.horizontal, TV.dp(18)).padding(.vertical, TV.dp(9))
                        .background(.white, in: Capsule())
                }
                .buttonStyle(TVRingButton(radius: TV.dp(30), ring: TV.accent))
                .focused($pfocus, equals: .skip)
            }
            .padding(.trailing, TV.dp(24)).padding(.bottom, TV.dp(28))
        }
        .transition(.opacity.combined(with: .offset(y: TV.dp(12))))
    }

    /// Flash pill: top-center, #E61B1830, r24dp, 16sp bold.
    private var tvFlash: some View {
        VStack {
            Text(flash).font(.system(size: TV.sp(16), weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, TV.dp(18)).padding(.vertical, TV.dp(10))
                .background(TV.argb(0xE61B1830), in: RoundedRectangle(cornerRadius: TV.dp(24)))
                .padding(.top, TV.dp(56))
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: captions side panel (right 300dp, #B3101018, stays open)
    private var tvCaptions: some View {
        HStack { Spacer()
            VStack(alignment: .leading, spacing: TV.dp(4)) {
                Text("CAPTIONS").font(.system(size: TV.sp(12.5), weight: .bold)).tracking(2).foregroundStyle(TV.dim)
                Text("Pick one — it plays right away. BACK closes.").font(.system(size: TV.sp(11.5))).foregroundStyle(TV.rgb(0x7E7B93))
                    .padding(.bottom, TV.dp(8))
                ScrollView {
                    VStack(alignment: .leading, spacing: TV.dp(2)) {
                        tvCaptionRow("Off", on: subIndex < 0) { pickSub(-1) }
                        ForEach(subTracks.indices, id: \.self) { i in
                            let t = subTracks[i]
                            tvCaptionRow(t["name"] as? String ?? t["lang"] as? String ?? "Track \(i + 1)", on: subIndex == i) { pickSub(i) }
                        }
                    }
                }
            }
            .padding(.leading, TV.dp(16)).padding(.top, TV.dp(18)).padding(.trailing, TV.dp(16)).padding(.bottom, TV.dp(14))
            .frame(width: TV.dp(300)).frame(maxHeight: .infinity)
            .background(TV.argb(0xB3101018))
            .focusSection()
        }
        .ignoresSafeArea()
    }

    private func tvCaptionRow(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(size: TV.sp(15), weight: on ? .bold : .regular))
                    .foregroundStyle(on ? TV.rgb(0xB9A6FF) : .white).lineLimit(2)
                Spacer()
                if on { Text("✓").font(.system(size: TV.sp(15), weight: .bold)).foregroundStyle(TV.rgb(0xB9A6FF)) }
            }
            .padding(TV.dp(12))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(10)))
    }

    // MARK: bottom pick sheets (Sheets.pick): #1B1830, top corners 18dp, selected = accent ✓
    private var tvSpeedSheet: some View {
        TVPickSheet(title: "Speed", options: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map { r in
            (r == 1 ? "Normal" : String(format: "%gx", r), rate == Float(r), { setRate(Float(r)); speedMenu = false; showControls() })
        })
    }
    private var tvAudioSheet: some View {
        TVPickSheet(title: "Audio", options: audioOpts.indices.map { i in
            (audioOpts[i].displayName, player.currentItem?.currentMediaSelection.selectedMediaOption(in: audioGroup!) == audioOpts[i], {
                if let g = audioGroup { player.currentItem?.select(audioOpts[i], in: g) }
                audioMenu = false; showControls()
            })
        })
    }

    // MARK: episode drawer (right 420dp, #E6101018)
    private var tvEpisodeDrawer: some View {
        HStack { Spacer()
            TVEpisodeDrawer(episodes: request.episodes, currentId: posKey()) { ep in
                showEpisodes = false; epTouched = true
                Task { await playEpisode(ep, idle: 0) }
            }
            .frame(width: TV.dp(420)).frame(maxHeight: .infinity)
            .background(TV.argb(0xE6101018))
        }
        .ignoresSafeArea()
    }

    // MARK: next-up card (bottom-end, slides in from the right, focus trap)
    func tvNextUp(_ ep: Episode) -> some View {
        let blur = !session.isWatched(ep.id) && session.pref("blurUnwatched", false)
        return VStack { Spacer()
            HStack { Spacer()
                HStack(alignment: .top, spacing: TV.dp(10)) {
                    AsyncImage(url: URL(string: ep.thumb ?? "")) { img in img.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { TV.argb(0x22FFFFFF) }
                        .frame(width: TV.dp(150), height: TV.dp(84)).blur(radius: blur ? 12 : 0).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: TV.dp(8)))
                    VStack(alignment: .leading, spacing: TV.dp(4)) {
                        Text("UP NEXT").font(.system(size: TV.sp(11), weight: .bold)).tracking(2.6).foregroundStyle(TV.rgb(0xB7B4C6))
                        Text("S\(ep.season)E\(ep.episode) · \(ep.name)").font(.system(size: TV.sp(14))).foregroundStyle(.white)
                            .lineLimit(2).frame(width: TV.dp(216), alignment: .leading)
                        HStack(spacing: TV.dp(8)) {
                            Button { epTouched = true; showNextUp = false; Task { await playEpisode(ep, idle: 0) } } label: {
                                Text("▶ Play now").font(.system(size: TV.sp(13), weight: .bold)).foregroundStyle(TV.rgb(0x0C0C14))
                                    .padding(.horizontal, TV.dp(16)).padding(.vertical, TV.dp(7))
                                    .background(.white, in: Capsule())
                            }
                            .buttonStyle(TVRingButton(radius: TV.dp(20), ring: TV.accent))
                            .focused($pfocus, equals: .upNext)
                            Button { epTouched = true; showNextUp = false; nextUpDismissed = true } label: {
                                Text("Dismiss").font(.system(size: TV.sp(13))).foregroundStyle(.white)
                                    .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(7))
                            }
                            .buttonStyle(TVRingButton(radius: TV.dp(20)))
                            .focused($pfocus, equals: .upDismiss)
                        }
                        .padding(.top, TV.dp(4))
                    }
                }
                .padding(TV.dp(10))
                .background(TV.argb(0xE61B1830), in: RoundedRectangle(cornerRadius: TV.dp(14)))
                .focusSection()
            }
            .padding(.trailing, TV.dp(24)).padding(.bottom, TV.dp(28))
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onAppear { pfocus = .upNext }
    }

    /// "Are you still watching?" (showStillWatching ~1210): 360dp, #1B1830, r22dp, 1dp #2C2649.
    var tvStillWatching: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: TV.dp(6)) {
                Image("Logo").resizable().scaledToFit().frame(height: TV.sp(34))
                Text("Are you still watching?").font(.system(size: TV.sp(18.5), weight: .bold)).foregroundStyle(.white)
                Text(request.meta.name).font(.system(size: TV.sp(14))).foregroundStyle(TV.dim)
                Button {
                    showStillWatching = false
                    if let ep = nextEp { Task { await playEpisode(ep, idle: 0) } } else { close() }
                } label: { tvPill("Keep watching", TV.accent) }
                .buttonStyle(TVRingButton(radius: TV.dp(26)))
                .focused($pfocus, equals: .keep)
                Button { close() } label: { tvPill("I'm done for now", TV.chip) }
                    .buttonStyle(TVRingButton(radius: TV.dp(26)))
                Text("No answer in 5 minutes and we'll tuck the stream in for the night 😴")
                    .font(.system(size: TV.sp(11.5))).foregroundStyle(TV.rgb(0x6A6590)).multilineTextAlignment(.center)
                    .padding(.top, TV.dp(6))
            }
            .padding(.horizontal, TV.dp(30)).padding(.top, TV.dp(24)).padding(.bottom, TV.dp(20))
            .frame(width: TV.dp(360))
            .background(TV.card, in: RoundedRectangle(cornerRadius: TV.dp(22)))
            .overlay(RoundedRectangle(cornerRadius: TV.dp(22)).stroke(TV.chip, lineWidth: TV.dp(1)))
        }
        .onAppear { pfocus = .keep }
    }

    private func tvPill(_ t: String, _ fill: Color) -> some View {
        Text(t).font(.system(size: TV.sp(15), weight: .bold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, TV.dp(12))
            .background(fill, in: RoundedRectangle(cornerRadius: TV.dp(26)))
            .padding(.top, TV.dp(10))
    }

    /// Loading: black, backdrop at 35%, the logo pulsing alpha 1 ↔ 0.3 every 800ms (title fallback).
    var tvLoading: some View {
        ZStack {
            Color.black
            AsyncImage(url: URL(string: request.meta.background ?? "")) { img in img.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Color.clear }
                .opacity(0.35).clipped()
            if let logo = request.meta.logo, let u = URL(string: logo) {
                AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: { EmptyView() }
                    .frame(width: TV.dp(320), height: TV.dp(120))
                    .modifier(TVPulse())
            } else {
                VStack(spacing: TV.dp(12)) {
                    Text(request.meta.name).font(.system(size: TV.sp(26), weight: .bold)).foregroundStyle(.white)
                    ProgressView().scaleEffect(1.6)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// DefaultTimeBar: played + scrubber #7B5BF5, buffered #667B5BF5, unplayed #33FFFFFF.
struct TVTimeBar: View {
    let pos: Int, dur: Int, buffered: Int
    @Environment(\.isFocused) private var focused
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let p = CGFloat(Double(pos) / Double(max(dur, 1)))
            let b = CGFloat(Double(buffered) / Double(max(dur, 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(TV.argb(0x33FFFFFF)).frame(height: TV.dp(4))
                Capsule().fill(TV.argb(0x667B5BF5)).frame(width: w * min(1, b), height: TV.dp(4))
                Capsule().fill(TV.accent).frame(width: w * min(1, p), height: TV.dp(4))
                Circle().fill(TV.accent).frame(width: TV.dp(focused ? 14 : 8), height: TV.dp(focused ? 14 : 8))
                    .offset(x: w * min(1, p) - TV.dp(focused ? 7 : 4))
            }
            .frame(height: TV.dp(26))
        }
        .frame(height: TV.dp(26))
    }
}

/// Sheets.pick bottom sheet: full width #1B1830, top corners 18dp, uppercase dim title, 16.5sp
/// rows, the current row in accent bold with a trailing ✓; focus lands on the current row.
struct TVPickSheet: View {
    let title: String
    let options: [(String, Bool, () -> Void)]
    @Namespace private var ns
    var body: some View {
        VStack { Spacer()
            VStack(alignment: .leading, spacing: TV.dp(2)) {
                Text(title.uppercased()).font(.system(size: TV.sp(12.5), weight: .bold)).tracking(2).foregroundStyle(TV.dim)
                    .padding(.leading, TV.dp(10)).padding(.bottom, TV.dp(6))
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    Button(action: o.2) {
                        HStack {
                            Text(o.0).font(.system(size: TV.sp(16.5), weight: o.1 ? .bold : .regular))
                                .foregroundStyle(o.1 ? TV.accent : .white)
                            Spacer()
                            if o.1 { Text("✓").font(.system(size: TV.sp(16.5), weight: .bold)).foregroundStyle(TV.accent) }
                        }
                        .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(11))
                    }
                    .buttonStyle(TVRingButton(radius: TV.dp(10)))
                    .prefersDefaultFocus(o.1, in: ns)
                }
            }
            .padding(.horizontal, TV.dp(14)).padding(.top, TV.dp(14)).padding(.bottom, TV.dp(16) + TV.dp(18))
            .frame(maxWidth: .infinity)
            .background(TV.card, in: RoundedRectangle(cornerRadius: TV.dp(18)))
            .padding(.bottom, -TV.dp(18))       // square off the bottom corners under the screen edge
            .focusScope(ns)
            .focusSection()
        }
        .ignoresSafeArea()
    }
}

/// Episode drawer: season tabs (current = accent text) + item_episode rows (128×72dp thumb,
/// "▶ ✓ S01E03\nName"); the current episode #9F86FF; unaired rows 40% and not focusable.
struct TVEpisodeDrawer: View {
    @EnvironmentObject var session: Session
    let episodes: [Episode]
    let currentId: String
    let onPick: (Episode) -> Void
    @State private var season = 0
    @Namespace private var ns
    private var seasons: [Int] { Array(Set(episodes.map(\.season))).filter { $0 > 0 }.sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: TV.dp(8)) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TV.dp(8)) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: {
                                Text("Season \(s)").font(.system(size: TV.sp(15)))
                                    .foregroundStyle(s == season ? TV.accent : .white)
                                    .padding(.horizontal, TV.dp(20)).padding(.vertical, TV.dp(10))
                            }
                            .buttonStyle(TVRingButton(radius: TV.dp(10)))
                        }
                    }
                }
                .focusSection()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }) { ep in
                        Button { onPick(ep) } label: {
                            HStack(alignment: .top, spacing: TV.dp(14)) {
                                AsyncImage(url: URL(string: ep.thumb ?? "")) { img in img.resizable().aspectRatio(contentMode: .fill) }
                                    placeholder: { TV.argb(0x22FFFFFF) }
                                    .frame(width: TV.dp(128), height: TV.dp(72)).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: TV.dp(8)))
                                Text(label(ep)).font(.system(size: TV.sp(15)))
                                    .foregroundStyle(ep.id == currentId ? TV.rgb(0x9F86FF) : .white).lineLimit(3)
                                Spacer(minLength: 0)
                            }
                            .padding(TV.dp(10))
                        }
                        .buttonStyle(TVRingButton(radius: TV.dp(10)))
                        .disabled(ep.unaired)
                        .opacity(ep.unaired ? 0.4 : 1)
                        .prefersDefaultFocus(ep.id == currentId, in: ns)
                    }
                }
            }
            .focusScope(ns)
        }
        .padding(TV.dp(16))
        .onAppear { season = episodes.first { $0.id == currentId }?.season ?? seasons.first ?? 0 }
    }
    private func label(_ ep: Episode) -> String {
        let mark = (ep.id == currentId ? "▶ " : "") + (session.isWatched(ep.id) ? "✓ " : "")
        return mark + String(format: "S%02dE%02d", ep.season, ep.episode) + "\n" + ep.name + (ep.unaired ? "\n(not aired)" : "")
    }
}

/// Logo pulse alpha 1 ↔ 0.3 every 800ms.
struct TVPulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
#endif
