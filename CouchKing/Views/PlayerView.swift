import SwiftUI
import AVKit
#if os(macOS)
import AppKit
#endif

// Player — Android PlayerActivity parity: /webplay remux fallback (initial open + mid-play
// stall), resume (local → server → mid-play reconcile), Skip Intro / Skip Recap with handled
// latches + 2s tail exclusion + slide-in, multi-stinger after-credits with the floor rule and
// the one-time toast, learned credits point, Next-Up card + prefetch-next from the REAL
// episode list (season-crossing), autoplay-next, ranked subtitle tracks + side panel, audio
// picker (audioLang default), speed, aspect cycle, seek-step controls, in-player episode
// panel, stats overlay, branded loading screen, live mode, progress heartbeat (instant
// start-stamp, 30s beats, 90s pushes, zombie guard), mark-watched-on-finish with
// credits-from-subtitles, "Are you still watching?".
struct PlayerView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) var dismiss
    @Environment(\.ckClose) var ckClose
    /// Leave the player: the Mac's in-window overlay closes through its host; elsewhere the
    /// system cover dismisses.
    func close() { if let ckClose { ckClose() } else { dismiss() } }
    let initialRequest: PlayRequest
    @State private var reqOverride: PlayRequest?
    /// The episode currently loaded. Next-Up swaps this IN PLACE (see reloadInPlace) instead
    /// of presenting a second PlayerView on top — that stacking was why hitting ✕ left the
    /// previous player still open, and two live players fighting over the audio session /
    /// PiP / orientation is the most likely "crashes every time" culprit.
    var request: PlayRequest { reqOverride ?? initialRequest }
    @State var player = AVPlayer()
    @State var windows = PlayerWindows()
    @State var posMs = 0
    @State var durMs = 0
    @State var subCues: [SubCue] = []
    @State var currentCue = ""
    // ---- watched tracking + account heartbeat (Android PlayerActivity ticker) ----
    @State var sessionStartMs = 0     // where this sit-down began (resume point)
    @State var beatCount = 0
    @State var lastBeatPos = -1       // zombie guard: only a MOVING position beats
    @State var startStamped = false
    @State var firstReported = false
    @State var finishedHandled = false
    // ---- "Are you still watching?" — 2 input-less auto-advances arm the modal ----
    @State var epTouched = false
    @State var showStillWatching = false
    @State var timeObserver: Any?
    @State var observers: [NSObjectProtocol] = []
    @State var rate: Float = 1.0      // playback speed (Android speed picker)
    @State var audioGroup: AVMediaSelectionGroup?
    @State var audioOpts: [AVMediaSelectionOption] = []   // multi-audio picker
    // ---- skip latches (Android *Handled): never re-show after skipping / crossing ----
    @State var introHandled = false
    @State var recapHandled = false
    @State var lastTickPos = 0        // seek-discontinuity detection
    // ---- after-credits ----
    @State var stingerToastShown = false
    @State var toast = ""
    // ---- next-up ----
    @State var nextReq: PlayRequest?  // prefetched (5 min before the end)
    @State var nextEp: Episode?
    @State var showNextUp = false
    @State var nextUpDismissed = false
    // ---- subtitles ----
    @State var subTracks: [[String: Any]] = []
    @State var subIndex = -1          // -1 = off
    @State var showSubPanel = false
    @State var flash = ""
    // ---- misc UI ----
    @State var scaleMode = "fit"
    @State var showStats = false
    @State var stats = ""
    @State var showEpisodes = false
    @State var firstFrame = false
    @State var failed = false
    @State var remuxed = false
    /// The absolute position the current remux session started at — the HLS clock restarts
    /// near 0 there, so every reported time is remuxBaseMs + player clock (web state.offset).
    @State var remuxBaseMs = 0
    /// a seek requested before the item was .readyToPlay — applied the moment it is
    @State var pendingSeekMs = -1
    @State var seeking = false   // remux reopen / buffering a seek → keep loading card, not black
    @State var subOffsetMs = 0   // manual subtitle sync nudge (per sit-down)
    /// Episode list fetched at open when the request came without one (CW resume etc.) —
    /// the Episodes button/panel and next-up need it no matter how playback started.
    @State var fetchedEpisodes: [Episode] = []
    var allEpisodes: [Episode] { request.episodes.isEmpty ? fetchedEpisodes : request.episodes }
    /// Title logo fetched when the request's meta came bare (list metas carry no logo) —
    /// the loading screen shows the show/movie's graphic title like Android.
    @State var titleLogo: String? = nil
    @State var titleBackdrop: String? = nil
    @State var serverAhead = 0        // mid-play reconcile: another device's position
    // ---- placeholder / "not yet available" clip (IOS_CONTRACTS §5) ----
    @State var placeholder = false
    @State var placeholderPoll: Task<Void, Never>?
    @State var swapped: [String: Any]?   // the real stream once it lands
    // ---- /webplay/probe (IOS_CONTRACTS §4) ----
    @State var probeInfo = ""
    @State var probedDurMs = 0   // true media duration from /webplay/probe (the remux HLS playlist only reports what's transcoded)
    @State var subxTask: Task<Void, Never>?
    @State var subxFrom = 0
    // ---- Picture-in-Picture + our own transport (the AVPlayerLayer surface has no native controls) ----
    @StateObject var pip = PiPModel()
    @State var playing = false
    @State var controlsVisible = true
    @State var hideTask: Task<Void, Never>?
    @State var scrubbing = false
    @State var scrubMs: Double = 0
    @State var volume: Double = 1          // desktop volume slider
    @State var speedMenu = false           // desktop / TV speed picker
    @State var audioMenu = false           // TV audio sheet
    @State var liveFav = false             // Live TV: ★ this channel
    // remote / keyboard focus (Apple TV: the Firestick-style "controls hidden → arrows seek")
    enum PFocus: Hashable { case picture, skip, play, seek, ctrl(String), upNext, upDismiss, keep }
    @FocusState var pfocus: PFocus?

    var isLive: Bool { request.meta.type == "tv" }
    /// The url actually playing (the real file after a placeholder hot-swap).
    var playURL: URL {
        if let u = swapped?["url"] as? String, let url = URL(string: u) { return url }
        return request.url
    }

    init(request: PlayRequest) { self.initialRequest = request }
    // legacy call sites (movie stream list) still hand us a bare url
    init(url: URL, meta: Meta) {
        self.initialRequest = PlayRequest(url: url, meta: meta, season: nil, episode: nil)
    }

    var body: some View {
        ZStack {
            PlayerSurface(player: player, gravity: gravity, pip: pip)
                .ignoresSafeArea()
            // tap on the picture = show/hide the controls (buttons above keep their own taps).
            // On Apple TV this layer is the remote's landing spot while the controls are hidden:
            // select shows them, left/right seek by the seek step, up/down show the controls.
            pictureCatcher
            #if os(tvOS)
            if !firstFrame && !failed { tvLoading }
            tvOverlay
            if placeholder { placeholderBanner }
            if showNextUp, let ep = nextEp { tvNextUp(ep) }
            if showStillWatching { tvStillWatching }
            #elseif os(macOS)
            if !firstFrame && !failed { loadingScreen }
            deskOverlay
            if placeholder { placeholderBanner }
            if showNextUp, let ep = nextEp { deskNextUp(ep) }
            if showStillWatching { deskStillWatching }
            #else
            if (!firstFrame || seeking) && !failed { loadingScreen }
            overlay
            if placeholder { placeholderBanner }
            if showNextUp, let ep = nextEp { nextUpCard(ep) }
            if showStillWatching { stillWatchingCard }
            #endif
            if failed { errorCard }
            #if os(iOS)
            if showSubPanel { subSidePanel.transition(.move(edge: .trailing)) }
            if showMiniGuide { miniGuidePanel.transition(.move(edge: .trailing)) }
            #endif
        }
        .background(.black)
        // any tap during an episode = someone's there → the idle chain resets
        .simultaneousGesture(TapGesture().onEnded { epTouched = true })
        #if os(tvOS)
        .onPlayPauseCommand { togglePlay() }
        .onExitCommand { tvBack() }   // Menu peels one layer: panels → next-up → controls → exit
        .onChange(of: skipKey) { k in if !k.isEmpty { pfocus = .skip } }   // skip pill takes focus
        #endif
        #if os(macOS)
        .background { deskKeys }
        .onContinuousHover { phase in
            if case .active = phase { if !controlsVisible { controlsVisible = true }; scheduleHide() }
        }
        #endif
        .onAppear { Task { await start() } }
        .onDisappear { stop() }
        #if os(tvOS) || os(macOS)
        .sheet(isPresented: $showSubPanel) {
            SubtitlePanel(tracks: subTracks, index: $subIndex, onPick: { i in
                pickSub(i); session.setPref("subLang", i < 0 ? "off" : "en")
            })
        }
        #endif
        #if os(iOS)

        .sheet(isPresented: $showEpisodes) {
            // NO detents: a medium sheet is illegal in landscape (compact height) and iOS
            // dismisses it the moment it appears — the "episode list opens then closes
            // instantly" bug. Full sheet works in both orientations.
            EpisodePanel(meta: request.meta, episodes: allEpisodes,
                         currentId: posKey()) { ep in
                showEpisodes = false
                epTouched = true
                Task { await playEpisode(ep, idle: 0) }
            }
            .id(posKey())   // play-next swaps the episode in place — rebuild so the purple
                            // current-episode highlight and auto-scroll follow (AJ)
        }
        #endif
    }

    var gravity: AVLayerVideoGravity {
        switch scaleMode {
        case "fill": return .resize
        case "zoom": return .resizeAspectFill
        default: return .resizeAspect
        }
    }

    // MARK: overlay

    /// Branded loading screen (Android buildLoadingScreen): show/channel art pulsing until
    /// the first frame lands.
    var loadingScreen: some View {
        // Android/Fire TV loading: the TITLE's logo art, else the title NAME big — never the
        // full poster, never the CouchKing brand mark (AJ Sep 30, both directions).
        ZStack {
            // the show/movie's backdrop, dimmed — the "cool loading screen" from Android
            if let bg = request.meta.background ?? titleBackdrop, let u = URL(string: bg) {
                AsyncImage(url: u) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.black }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(.black.opacity(0.55))
                .ignoresSafeArea()
            }
        VStack(spacing: 12) {
            if let lg = request.meta.logo ?? titleLogo, let u = URL(string: lg) {
                AsyncImage(url: u) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Text(request.meta.name).font(.title2.bold()).multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: 280, maxHeight: 130)
                .modifier(Pulse())
            } else {
                Text(request.meta.name).font(.title2.bold()).multilineTextAlignment(.center)
                    .foregroundStyle(.white).padding(.horizontal, 30)
                    .modifier(Pulse())
            }
            if isLive {
                Text("Tuning…").font(.headline).foregroundStyle(.white.opacity(0.9))
            }
            if let s = request.season, let e = request.episode {
                Text("S\(s) E\(e)").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView().tint(.white).padding(.top, 6)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    /// Android-style center transport: back-step, big play/pause, forward-step in the MIDDLE
    /// of the screen (AJ: "can't play pause in the middle of the screen or skip 10 secs").
    var centerCluster: some View {
        HStack(spacing: 44) {
            if !isLive && !placeholder {
                let step = session.pref("seekStep", 10)
                SeekButton(icon: "gobackward", label: "\(step)") { epTouched = true; seek(ms: max(0, posMs - step * 1000)); scheduleHide() }
            }
            Button { togglePlay(); scheduleHide() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 68, height: 68)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(playing ? "Pause" : "Play")
            .focused($pfocus, equals: .play)
            if !isLive && !placeholder {
                let step = session.pref("seekStep", 10)
                SeekButton(icon: "goforward", label: "\(step)") { epTouched = true; seek(ms: posMs + step * 1000); scheduleHide() }
            }
        }
    }

    @ViewBuilder var overlay: some View {
        ZStack {
        if controlsVisible && !failed && firstFrame { centerCluster.transition(.opacity) }
        VStack {
            if controlsVisible { topBar.transition(.opacity) }
            if showStats {
                Text(stats).font(.system(size: 11, design: .monospaced))
                    .padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            Spacer()
            if !toast.isEmpty {
                Text(toast).font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .transition(.opacity)
            }
            if !flash.isEmpty {
                Text(flash).font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.85), in: Capsule())
                    .transition(.opacity)
            }
            if serverAhead > 0 {
                Button {
                    let p = serverAhead; serverAhead = 0; epTouched = true
                    seek(ms: p); flashLabel("Jumped to \(clock(p))")
                } label: {
                    Text("Another device is at \(clock(serverAhead)) — jump there")
                        .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.92), in: Capsule()).foregroundStyle(.black)
                }
            }
            if !currentCue.isEmpty {
                SubtitleText(text: currentCue)
                    .padding(.bottom, subBottomPad)
            }
            // the skip pill never hides with the controls (seek steps live in the center now)
            HStack(spacing: 10) {
                Spacer()
                skipButton
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .animation(.easeOut(duration: 0.25), value: skipKey)
            .padding(.horizontal, 20)
            .padding(.bottom, controlsVisible ? 8 : 40)
            if controlsVisible { transportBar.transition(.opacity) }
        }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    // ---- in-player MINI GUIDE (Android Sep 26): channel strip while watching live ----
    #if os(iOS)
    @State var showMiniGuide = false
    @State var miniChannels: [LiveChannel] = []
    @State var miniSections: [(String, [LiveChannel])] = []
    var miniGuidePanel: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Guide").font(.subheadline.bold())
                    Spacer()
                    Button { withAnimation { showMiniGuide = false } } label: { Image(systemName: "xmark") }
                }
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 12)
                Divider().overlay(Theme.card2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(miniSections, id: \.0) { title, chans in
                            if !title.isEmpty {
                                Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                            }
                            ForEach(chans) { ch in
                            Button {
                                withAnimation { showMiniGuide = false }
                                Task { await switchLive(ch) }
                            } label: {
                                HStack(spacing: 8) {
                                    AsyncImage(url: URL(string: ch.logo)) { img in
                                        img.resizable().aspectRatio(contentMode: .fit)
                                    } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
                                    .frame(width: 34, height: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(ch.name).font(.caption.bold()).lineLimit(1)
                                        Text(ch.now(LiveTV.nowMs())?.t ?? "").font(.caption2)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(ch.id == request.meta.id ? Theme.accent : .white)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(width: 280)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.85))
        }
        .task {
            guard miniChannels.isEmpty else { return }
            let region = UserDefaults.standard.string(forKey: "liveRegion") ?? ""
            if case .ok(let g) = await LiveTV.guide(session, region: region) {
                let favs = Set(g.favs)
                miniChannels = g.favChannels + g.channels.filter { !favs.contains($0.id) }
                // sectioned like the Live TV page: ★ Favorites, then each category
                var out: [(String, [LiveChannel])] = []
                if !g.favChannels.isEmpty { out.append(("★ FAVORITES", g.favChannels)) }
                var bySec: [String: [LiveChannel]] = [:]; var order: [String] = []
                for c in g.channels where !favs.contains(c.id) {
                    if bySec[c.section] == nil { order.append(c.section) }
                    bySec[c.section, default: []].append(c)
                }
                for sec in order { out.append((sec.isEmpty ? "CHANNELS" : sec.uppercased(), bySec[sec] ?? [])) }
                miniSections = out
            }
        }
    }
    /// Channel zap without leaving the player (Android mini-guide tune).
    func switchLive(_ ch: LiveChannel) async {
        guard let base = session.addonBase() else { return }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = try? await API.json("/stream/tv/\(ch.id).json?u=\(u)", base: base),
              let st = (r["streams"] as? [[String: Any]])?.first(where: { ($0["url"] as? String)?.isEmpty == false }),
              let us = st["url"] as? String, let url = URL(string: us) else {
            flashLabel("No feed for \(ch.name)"); return
        }
        await reloadInPlace(PlayRequest(url: url, meta: ch.meta(LiveTV.nowMs()), season: nil, episode: nil))
    }
    #endif

    /// Right-side captions strip (Android live-captions panel) — narrow, so you can still
    /// watch while picking a track. Full style options behind the ⚙︎.
    #if os(iOS)
    @State private var subLook = false
    var subSidePanel: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Subtitles").font(.subheadline.bold())
                    Spacer()
                    Button { subLook = true } label: { Image(systemName: "textformat.size") }
                    Button { withAnimation { showSubPanel = false } } label: { Image(systemName: "xmark") }
                }
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 12)
                Divider().overlay(Theme.card2)
                // sync nudge: shift every cue ±0.5s — mis-timed subs for a given release are
                // fixable on the spot (the offset rides the session, resets per title)
                HStack(spacing: 10) {
                    Text("Sync").font(.caption).foregroundStyle(.secondary)
                    Button { subOffsetMs -= 500; flashLabel("Subs \(subOffsetMs >= 0 ? "+" : "")\(Double(subOffsetMs) / 1000)s") } label: { Image(systemName: "minus.circle") }
                    Text(String(format: "%+.1fs", Double(subOffsetMs) / 1000)).font(.caption.monospacedDigit())
                    Button { subOffsetMs += 500; flashLabel("Subs \(subOffsetMs >= 0 ? "+" : "")\(Double(subOffsetMs) / 1000)s") } label: { Image(systemName: "plus.circle") }
                }
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                Divider().overlay(Theme.card2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        subRow("Off", on: subIndex < 0) { pickSub(-1); session.setPref("subLang", "off") }
                        ForEach(subTracks.indices, id: \.self) { i in
                            subRow(subTracks[i]["lang"] as? String ?? subTracks[i]["name"] as? String ?? "Track \(i+1)",
                                   on: subIndex == i) { pickSub(i); session.setPref("subLang", "en") }
                        }
                    }
                }
            }
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.82))
        }
        .sheet(isPresented: $subLook) { SubtitleLookSheet() }   // no detents — landscape dismisses medium sheets
    }
    func subRow(_ label: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack {
                Text(label).font(.callout).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .foregroundStyle(on ? Theme.accent : .white)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    /// Close · Ends · PiP · AirPlay · more (subtitles / audio / speed / aspect / episodes / stats).
    var topBar: some View {
        HStack(spacing: 8) {
            Button { close() } label: {
                Image(systemName: "xmark").padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            Spacer()
            // "Ends 9:47 PM" — hidden in live mode (rolling HLS duration lies) and while a
            // placeholder clip loops. Android ticker.
            if durMs > 1000 && !isLive && !placeholder {
                Text(endsText).font(.caption).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            Spacer()
            // Picture-in-Picture pop-out (top corner, next to AirPlay)
            if PiPModel.supported {
                Button { epTouched = true; pip.toggle(); scheduleHide() } label: {
                    Image(systemName: pip.active ? "pip.exit" : "pip.enter").padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(!pip.possible && !pip.active)
                .opacity(pip.possible || pip.active ? 1 : 0.4)
                .accessibilityLabel(pip.active ? "Exit picture in picture" : "Picture in picture")
            }
            if !Platform.isTV {
                AirPlayButton()
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
        .padding()
    }

    /// Play/pause + scrubber with elapsed / remaining — replaces the native AVPlayerViewController
    /// controls the layer surface doesn't have. Live mode: play/pause + LIVE badge, no scrubber.
    var transportBar: some View {
      VStack(spacing: 6) {
        HStack(spacing: 10) {
            if isLive {
                Text("LIVE").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                Spacer()
            } else if durMs > 0 && !placeholder {
                let shown = scrubbing ? Int(scrubMs) : posMs
                Text(clock(shown)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                #if os(tvOS)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(Theme.accent)
                            .frame(width: g.size.width * CGFloat(Double(shown) / Double(max(durMs, 1))))
                    }
                }
                .frame(height: 8)
                #else
                Slider(value: Binding(get: { scrubbing ? scrubMs : Double(posMs) },
                                      set: { scrubMs = $0 }),
                       in: 0...Double(max(durMs, 1)),
                       onEditingChanged: { editing in
                           if editing {
                               scrubbing = true; scrubMs = Double(posMs); hideTask?.cancel()
                           } else {
                               scrubbing = false; epTouched = true
                               seek(ms: Int(scrubMs)); scheduleHide()
                           }
                       })
                    .tint(Theme.accent)
                #endif
                Text("-" + clock(max(0, durMs - shown))).font(.caption.monospacedDigit()).foregroundStyle(.white)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        // Android's bottom button row: Captions · Audio · Speed · Aspect · Episodes · Stats —
        // labeled buttons on the bar, no hidden "…" menu (AJ: "there is 3 dots… I hate it").
        #if !os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !subTracks.isEmpty {
                    barButton("Captions", "captions.bubble") { showSubPanel = true; hideTask?.cancel() }
                }
                if audioOpts.count > 1 {
                    Menu {
                        ForEach(audioOpts.indices, id: \.self) { i in
                            Button(audioOpts[i].displayName) {
                                if let g = audioGroup { player.currentItem?.select(audioOpts[i], in: g) }
                                flashLabel("Audio: \(audioOpts[i].displayName)")
                            }
                        }
                    } label: { barLabel("Audio", "waveform") }
                }
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button { setRate(Float(r)) } label: {
                            Text(rate == Float(r) ? "✓ \(r, specifier: "%g")×" : "\(r, specifier: "%g")×")
                        }
                    }
                } label: { barLabel(rate == 1 ? "Speed" : String(format: "%g×", rate), "speedometer") }
                barButton("Screen", "aspectratio") { cycleScale() }
                if request.season != nil && !allEpisodes.isEmpty {
                    barButton("Episodes", "list.bullet.rectangle") { showEpisodes = true; hideTask?.cancel() }
                }
                #if os(iOS)
                if isLive {
                    barButton("Guide", "list.bullet.below.rectangle") { showMiniGuide = true; hideTask?.cancel() }
                }
                #endif
                barButton("Stats", "chart.bar") { showStats.toggle() }
            }
            .padding(.horizontal, 20)
        }
        #endif
      }
        .padding(.bottom, 24)
    }

    /// One labeled pill on the transport bar (Android's labeled control buttons).
    func barLabel(_ label: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13))
            Text(label).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.black.opacity(0.5), in: Capsule())
        .foregroundStyle(.white)
    }
    func barButton(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: { barLabel(label, icon) }
    }

    /// The picture itself: tap (phone/Mac) toggles the controls. On Apple TV it is focusable while
    /// the controls are hidden — select shows them, left/right seek (Firestick remote), up/down
    /// bring the controls back.
    @ViewBuilder var pictureCatcher: some View {
        #if os(tvOS)
        // Firestick: hidden controller → OK = play/pause, any arrow shows the controller
        Color.clear
            .ignoresSafeArea()
            .focusable(!controlsVisible)
            .focused($pfocus, equals: .picture)
            .onTapGesture { epTouched = true; togglePlay(); showControls() }
            .onMoveCommand { _ in epTouched = true; showControls() }
        #elseif os(macOS)
        // desktop: click the video = play/pause (and close any open menu)
        Color.clear.contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture {
                if speedMenu || showSubPanel || showStats { speedMenu = false; showSubPanel = false; showStats = false }
                else { togglePlay() }
                controlsVisible = true; scheduleHide()
            }
        #else
        Color.clear.contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture { toggleControls() }
        #endif
    }

    func remoteSeek(_ dir: Int) {
        guard !isLive, !placeholder else { showControls(); return }
        let step = session.pref("seekStep", 10) * 1000
        seek(ms: max(0, posMs + dir * step))
        flashLabel(dir < 0 ? "⟲ \(step / 1000)s" : "⟳ \(step / 1000)s")
    }

    func showControls() {
        controlsVisible = true
        #if os(tvOS)
        pfocus = (isLive || placeholder) ? .play : .seek   // Firestick focuses the time bar
        #endif
        scheduleHide()
    }

    func togglePlay() {
        epTouched = true
        if player.timeControlStatus == .paused {
            player.play()          // resumes at defaultRate, so the chosen speed sticks
            playing = true
        } else {
            player.pause()
            playing = false
        }
        scheduleHide()
    }

    /// Tap the picture: show the controls (and re-arm the auto-hide), or hide them.
    func toggleControls() {
        epTouched = true
        if controlsVisible {
            hideTask?.cancel(); controlsVisible = false
            #if os(tvOS)
            pfocus = .picture
            #endif
        } else { showControls() }
    }

    /// Controls fade out 4s after the last interaction while playing; they stay while paused
    /// or scrubbing.
    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            #if os(tvOS)
            try? await Task.sleep(for: .seconds(5))      // Firestick controller timeout
            #elseif os(macOS)
            try? await Task.sleep(for: .seconds(3))      // desktop mouse-idle
            #else
            try? await Task.sleep(for: .seconds(4))
            #endif
            guard !Task.isCancelled else { return }
            if playing && !scrubbing && !showSubPanel && !showEpisodes && !speedMenu && !audioMenu {
                controlsVisible = false
                #if os(tvOS)
                if pfocus != .skip { pfocus = .picture }
                #endif
            }
        }
    }

    /// Subtitle position pref: normal / raised / high (Android applySubtitle position).
    var subBottomPad: CGFloat {
        switch session.pref("subPos", "normal") {
        case "high": return 90
        case "raised": return 48
        default: return 8
        }
    }

    @ViewBuilder var menuItems: some View {
        if !subTracks.isEmpty {
            Button { showSubPanel = true } label: { Label("Subtitles", systemImage: "captions.bubble") }
        }
        if audioOpts.count > 1 {
            Menu {
                ForEach(audioOpts.indices, id: \.self) { i in
                    Button(audioOpts[i].displayName) {
                        if let g = audioGroup { player.currentItem?.select(audioOpts[i], in: g) }
                        flashLabel("Audio: \(audioOpts[i].displayName)")
                    }
                }
            } label: { Label("Audio", systemImage: "waveform") }
        }
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button { setRate(Float(r)) } label: {
                    Text(rate == Float(r) ? "✓ \(r, specifier: "%g")×" : "\(r, specifier: "%g")×")
                }
            }
        } label: { Label("Speed", systemImage: "speedometer") }
        Button { cycleScale() } label: { Label("Aspect: \(scaleMode.capitalized)", systemImage: "aspectratio") }
        if request.season != nil && !allEpisodes.isEmpty {
            Button { showEpisodes = true } label: { Label("Episodes", systemImage: "list.bullet.rectangle") }
        }
        Button { showStats.toggle() } label: { Label(showStats ? "Hide stats" : "Stats", systemImage: "chart.bar") }
    }

    /// The pill currently offered (drives the slide-in animation).
    var skipKey: String {
        if let s = skipState { return s.0 }
        return ""
    }

    /// Recap before intro (precedence), handled latches, 2s tail exclusion, then after-credits
    /// stingers with the floor rule and "(1/2)" sequential labels (Android ticker ~L694-740).
    var skipState: (String, Int)? {
        let tail = 2000
        if windows.recapFrom > 0, !recapHandled, posMs >= windows.recapFrom, posMs < windows.recapTo - tail {
            return ("Skip Recap", windows.recapTo)
        }
        if windows.introFrom > 0, !introHandled, posMs >= windows.introFrom, posMs < windows.introTo - tail {
            return ("Skip Intro", windows.introTo)
        }
        guard durMs > 0, !windows.afterCredits.isEmpty else { return nil }
        let stingers = windows.afterCredits.filter { $0.count >= 1 && $0[0] > 0 }.sorted { $0[0] < $1[0] }
        let finish = finishPointMs(durMs)
        for (i, st) in stingers.enumerated() {
            let start = st[0]
            let prevEnd = i > 0 ? (stingers[i - 1].count > 1 ? stingers[i - 1][1] : stingers[i - 1][0]) : 0
            let floor = max(finish, max(start - 90_000, prevEnd))
            if posMs >= floor, posMs < start - 1000 {
                let label = stingers.count > 1 ? "After credits (\(i + 1)/\(stingers.count)) ▶" : "After credits ▶"
                return (label, start)
            }
        }
        return nil
    }

    /// "Getting this ready…" strip while the placeholder clip loops (Android placeholder branch).
    var placeholderBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Getting this ready — playback starts automatically when it lands.")
                    .font(.caption).foregroundStyle(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.bottom, 96)
        }
    }

    @ViewBuilder var skipButton: some View {
        if placeholder { EmptyView() }
        else if let st = skipState {
            SkipPill(text: st.0, focus: $pfocus) {
                epTouched = true
                if st.0 == "Skip Recap" { recapHandled = true }
                if st.0 == "Skip Intro" { introHandled = true }
                seek(ms: st.1)
            }
        }
    }

    /// Next-Up card (Android showNextUpCard): thumbnail (blurred if unwatched + pref), title,
    /// Play / Dismiss. Shown by time-remaining OR crossed credits point; never interrupts.
    func nextUpCard(_ ep: Episode) -> some View {
        let blur = !session.isWatched(ep.id) && session.pref("blurUnwatched", false)
        return VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: ep.thumb ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Theme.card }
                    .frame(width: 120, height: 68).blur(radius: blur ? 8 : 0).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next up").font(.caption).foregroundStyle(.secondary)
                        Text("S\(ep.season) E\(ep.episode) · \(ep.name)").font(.subheadline.bold()).lineLimit(2)
                        HStack(spacing: 8) {
                            Button {
                                epTouched = true; showNextUp = false
                                Task { await playEpisode(ep, idle: 0) }
                            } label: {
                                Text("Play").font(.caption.bold()).padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                            }
                            Button("Dismiss") { epTouched = true; showNextUp = false; nextUpDismissed = true }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Theme.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 360)
            }
            .padding(.trailing, 16).padding(.bottom, controlsVisible ? 120 : 24)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// Crown + Keep watching / I'm done. BACK-out = dismiss; no answer for 5 minutes =
    /// playback stops and the player exits (Android showStillWatching).
    var stillWatchingCard: some View {
        VStack(spacing: 14) {
            Image("Logo").resizable().scaledToFit().frame(height: 48)
            Text("Are you still watching?").font(.title3.bold())
            Button {
                showStillWatching = false
                if let ep = nextEp { Task { await playEpisode(ep, idle: 0) } } else { close() }
            } label: {
                Text("Keep watching").font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button("I'm done") { close() }
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }

    /// Player error handling (Android onPlayerError): remux once, then Retry / Close.
    var errorCard: some View {
        VStack(spacing: 14) {
            Text("⚠️").font(.system(size: 36))
            Text("Playback failed").font(.title3.bold())
            Text(remuxed ? "The stream stopped and couldn't be recovered." : "Trying another route…")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Retry") { failed = false; remuxed = false; firstFrame = false; playRemux(fromMs: posMs) }
                    .font(.headline).padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                Button("Close") { close() }.foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }

    // "Ends" clock — remaining runtime (÷ speed) added to now (Android ends-at readout).
    var endsText: String {
        let remain = Double(max(0, durMs - posMs)) / 1000.0 / Double(max(0.1, rate))
        let f = DateFormatter(); f.timeStyle = .short
        return "Ends \(f.string(from: Date().addingTimeInterval(remain)))"
    }

    func clock(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func flashLabel(_ text: String) {
        withAnimation { flash = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if flash == text { withAnimation { flash = "" } }
        }
    }

    /// Playback speed (Android showSpeedPicker) — defaultRate keeps it across pause/play (iOS 16+).
    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if player.timeControlStatus == .playing { player.rate = r }
        flashLabel(String(format: "%g×", r))
    }

    /// Aspect cycle fit → fill → zoom, persisted per profile (Android cycleScale / scaleMode).
    func cycleScale() {
        let order = ["fit", "fill", "zoom"]
        let i = order.firstIndex(of: scaleMode) ?? 0
        scaleMode = order[(i + 1) % order.count]
        session.setPref("scaleMode", scaleMode)
        flashLabel("Aspect: \(scaleMode.capitalized)")
    }

    // MARK: lifecycle

    func start() async {
        // keep-screen-on while playing (Android FLAG_KEEP_SCREEN_ON fix, Sep 18)
        Platform.keepAwake(true)
        Platform.lockLandscape(true)
        PlaybackAudio.activate()   // .playback: sound on silent, in background, in the PiP window
        scaleMode = session.pref("scaleMode", "fit")
        if !isLive {
            windows = await PlayerWindows.fetch(session: session, id: request.meta.id,
                                                season: request.season, episode: request.episode)
            // chapter windows riding on the stream object override /player/resume (Android
            // `windows` intent extra)
            if let sw = request.streamWindows, sw.hasWindows { windows.adopt(sw) }
        }
        player.allowsExternalPlayback = true   // native AirPlay — sends the real video to the TV
        placeholder = request.placeholder
        let item = AVPlayerItem(url: request.url)
        player.replaceCurrentItem(with: item)
        observeItem(item)
        if placeholder { startPlaceholderPoll() }
        else if !isLive { Task { await probeMedia() } }
        // audio: the audioLang pref picks the default track (Android audioLang), English fallback
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            let opts = group.options
            let want = session.pref("audioLang", "en")
            let match = { (o: AVMediaSelectionOption, code: String) -> Bool in
                (o.locale?.language.languageCode?.identifier ?? "").hasPrefix(code)
            }
            var pick: AVMediaSelectionOption? = nil
            if want != "any" {
                pick = opts.first { match($0, want) } ?? opts.first { match($0, "en") }
                    ?? opts.first { $0.displayName.lowercased().contains("english") }
            }
            if let pick { item.select(pick, in: group) }
            await MainActor.run { audioGroup = group; audioOpts = opts }
        }
        // resume: local positions map first (synced), server pos as fallback — never in live mode
        // or on a placeholder clip
        var resume = 0
        if !isLive && !placeholder {
            let local = ((session.pstate()["positions"] as? [String: Any])?[posKey()] as? String)?
                .split(separator: "|").first.flatMap { Int($0) } ?? 0
            resume = max(local, windows.resumeMs)
        }
        let r0 = resume
        // KNOWN-BAD CONTAINER: don't waste up to 12s waiting for AVPlayer to fail on an MKV —
        // go straight to the /webhls remux at the resume point (AJ: "playing and skipping
        // around should be smooth").
        if !isLive, !placeholder, request.url.path.lowercased().hasSuffix(".mkv") {
            playRemux(fromMs: r0)
            if r0 > 0 { sessionStartMs = r0 }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 40),
                                                          queue: .main) { t in
                Task { @MainActor in tick(remuxBaseMs + Self.safeMs(t.seconds)) }
            }
            subTracks = rankSubtitles(request.subtitles)
            await loadSubtitles()
        await mergeV3Subs()
            await fetchMetaExtras()
        nextEp = computeNextEpisode()
            return
        }
        // DON'T seek a not-ready item (the resume/fast-forward "stuck & crash" bug — seeking an
        // AVPlayerItem whose status is still .unknown, esp. an MKV AVPlayer can't even open,
        // hangs the surface). Wait for readiness, THEN seek+play; a container AVPlayer can't
        // open goes .failed → the /webhls remux opened AT r0 (no seek needed there).
        Task { @MainActor in
            for _ in 0..<120 {                       // up to ~12s
                if item.status == .readyToPlay {
                    if r0 > 120_000 && !remuxed {
                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                            player.seek(to: CMTime(seconds: Double(r0) / 1000, preferredTimescale: 1000),
                                        toleranceBefore: .zero, toleranceAfter: .zero) { _ in c.resume() }
                        }
                        sessionStartMs = r0
                    }
                    player.play()
                    return
                }
                if item.status == .failed { if !remuxed { playRemux(fromMs: r0) }; return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !remuxed { playRemux(fromMs: r0) }    // never became ready → remux as a last resort
        }
        // position ticker drives skip buttons + subtitle cues + the account heartbeat
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 40),
                                                      queue: .main) { t in
            Task { @MainActor in tick(remuxBaseMs + Self.safeMs(t.seconds)) }
        }
        subTracks = rankSubtitles(request.subtitles)
        await loadSubtitles()
        await mergeV3Subs()
        // next episode from the REAL episode list (season-crossing, no e+1 guessing)
        await fetchMetaExtras()
        nextEp = computeNextEpisode()
    }

    /// Fill in what a bare PlayRequest lacks: the episode list (CW resume has none — the
    /// Episodes button vanished) and the title LOGO for the loading screen (list metas
    /// carry no logo; Android always shows the graphic title).
    func fetchMetaExtras() async {
        guard !isLive, !placeholder else { return }
        if (request.meta.logo ?? "").isEmpty || (request.season != nil && request.episodes.isEmpty) {
            let m = await Catalog.fullMeta(session: session, type: request.season != nil ? "series" : "movie",
                                           id: request.meta.id)
            if titleLogo == nil, let lg = m["logo"] as? String, !lg.isEmpty { titleLogo = lg }
            if titleBackdrop == nil, let bg = m["background"] as? String, !bg.isEmpty { titleBackdrop = bg }
            if request.season != nil, fetchedEpisodes.isEmpty {
                fetchedEpisodes = (m["videos"] as? [[String: Any]] ?? []).compactMap(Episode.init)
            }
        }
    }

    func observeItem(_ item: AVPlayerItem) {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                object: item, queue: .main) { _ in
            Task { @MainActor in onEnded() }
        })
        // mid-play stall (Android onPlayerError): hand the same position to the remux once
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                                object: item, queue: .main) { _ in
            Task { @MainActor in onError() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemNewErrorLogEntry,
                                                                object: item, queue: .main) { _ in
            Task { @MainActor in if item.status == .failed { onError() } }
        })
    }

    @State var errorRetried = false
    func onError() {
        if !remuxed { playRemux(fromMs: posMs); return }
        if !errorRetried {
            // a fast double-seek kills the previous transcode session mid-handshake and the
            // player reports failure — one silent reopen at the same spot rescues it
            errorRetried = true
            playRemux(fromMs: posMs)
            Task { try? await Task.sleep(for: .seconds(6)); errorRetried = false }
            return
        }
        failed = true
    }


    /// NaN/∞-safe CMTime→ms (Int(NaN) is a Swift runtime CRASH — currentTime() on a torn-down
    /// or failed item returns invalid time; this was the "crashes when I try to play" bug).
    nonisolated static func safeMs(_ seconds: Double) -> Int { seconds.isFinite ? Int(seconds * 1000) : 0 }

    func posKey() -> String {
        if let s = request.season, let e = request.episode { return "\(request.meta.id):\(s):\(e)" }
        return request.meta.id
    }

    // MARK: ticker

    func tick(_ ms: Int) {
        // a seek requested while the item was loading — apply it now that frames flow
        if pendingSeekMs >= 0, !remuxed, let it = player.currentItem, it.status == .readyToPlay {
            let t = pendingSeekMs; pendingSeekMs = -1
            player.seek(to: CMTime(seconds: Double(t) / 1000, preferredTimescale: 1000),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        let prev = lastTickPos
        let nowPlaying = player.timeControlStatus != .paused
        if nowPlaying != playing {
            playing = nowPlaying
            if !nowPlaying { hideTask?.cancel(); controlsVisible = true }   // paused → controls stay up
        }
        posMs = ms
        lastTickPos = ms
        if !firstFrame, player.rate > 0, ms > 0 { firstFrame = true; seeking = false; scheduleHide() }
        else if seeking, player.timeControlStatus == .playing { seeking = false }
        let cueMs = ms - subOffsetMs
        currentCue = subCues.first(where: { cueMs >= $0.from && cueMs <= $0.to })?.text ?? ""
        // seek discontinuity (Android onPositionDiscontinuity / pendingIntroFrom): jumping back
        // BEFORE a window re-arms its latch; crossing a window's end without skipping latches it
        if abs(ms - prev) > 3000 {
            if windows.introFrom > 0 && ms < windows.introFrom { introHandled = false }
            if windows.recapFrom > 0 && ms < windows.recapFrom { recapHandled = false }
            // an embedded track streamed from `t` has nothing before it — re-stream on a big seek back
            if subIndex >= 0, subIndex < subTracks.count, let idx = subTracks[subIndex]["embedded"] as? Int,
               ms < subxFrom {
                subCues = []
                streamEmbedded(index: idx, track: subIndex, fromMs: max(0, ms - 30_000))
            }
        }
        if windows.introTo > 0 && prev < windows.introTo && ms >= windows.introTo { introHandled = true }
        if windows.recapTo > 0 && prev < windows.recapTo && ms >= windows.recapTo { recapHandled = true }
        if isLive || placeholder { return }
        heartbeat()
        stingerNudge()
        nextUpTick()
        if showStats && beatCount % 2 == 0 { updateStats() }
    }

    /// One-time "🎬 This movie has a scene during/after the credits" ~4 min before the first
    /// stinger (Android stinger nudge ~L778-785).
    func stingerNudge() {
        guard !stingerToastShown, request.season == nil,
              let first = windows.afterCredits.compactMap({ $0.first }).min(), first > 0,
              posMs >= first - 240_000, posMs < first - 200_000 else { return }
        stingerToastShown = true
        withAnimation { toast = "🎬 This movie has a scene during/after the credits" }
        Task {
            try? await Task.sleep(for: .seconds(6))
            withAnimation { toast = "" }
        }
    }

    /// Prefetch the next episode's stream 5 min out (instant advance) and show the Next-Up
    /// card by time-remaining or once the credits point is crossed.
    func nextUpTick() {
        guard durMs > 0, request.season != nil, let ep = nextEp else { return }
        let remain = durMs - posMs
        if nextReq == nil && remain <= 300_000 { Task { await prefetchNext(ep) } }
        let credits = finishPointMs(durMs)
        if !showNextUp && !nextUpDismissed && (remain <= 30_000 || posMs >= credits) && posMs > 60_000 {
            withAnimation { showNextUp = true }
        }
    }

    /// Android ticker parity: instant start-stamp (the moment playback starts, stamp + push
    /// so other devices resume-target immediately), first report ~20s in then every 30s,
    /// local resume bar every 30s, account blob every 90s — all gated on a MOVING position
    /// (the zombie guard: a stick frozen "playing" for 26h must never pin CW everywhere).
    func heartbeat() {
        if remuxed { if probedDurMs > 0 { durMs = probedDurMs } }
        else if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { durMs = Int(d * 1000) }
        beatCount += 1
        guard player.rate > 0, durMs > 0, !finishedHandled else { return }
        if !startStamped {
            startStamped = true
            savePos(max(posMs, 500), durMs, push: true)
        }
        let moved = posMs != lastBeatPos
        if !firstReported && posMs >= 20_000 {
            firstReported = true
            session.reportProgress(id: request.meta.id, season: request.season,
                                   episode: request.episode, pos: posMs, dur: durMs)
        } else if beatCount % 30 == 0 && moved {
            session.reportProgress(id: request.meta.id, season: request.season,
                                   episode: request.episode, pos: posMs, dur: durMs)
        }
        if beatCount % 30 == 0 && posMs >= 1000 && moved {
            lastBeatPos = posMs
            savePos(posMs, durMs, push: false)   // local bar; the blob rides the 90s push
        }
        if beatCount % 90 == 0 && moved {
            session.push()
            Task { await reconcileServer() }
        }
    }

    /// Mid-play resume conflict (Android start() server-state block): if another device is
    /// >60s AHEAD on this same episode, offer the jump instead of silently overwriting it.
    func reconcileServer() async {
        let w = await PlayerWindows.fetch(session: session, id: request.meta.id,
                                          season: request.season, episode: request.episode)
        if w.resumeMs > posMs + 60_000, w.resumeMs < durMs { serverAhead = w.resumeMs }
    }

    /// Stats overlay (Android updateStats): resolution / fps / dropped frames / bitrate.
    func updateStats() {
        guard let item = player.currentItem else { return }
        let size = item.presentationSize
        var fps = 0.0
        if let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }) {
            fps = Double(track.currentVideoFrameRate)
        }
        let log = item.accessLog()?.events.last
        let dropped = log?.numberOfDroppedVideoFrames ?? 0
        let kbps = Int((log?.observedBitrate ?? 0) / 1000)
        stats = String(format: "%.0f×%.0f  %.1f fps  dropped %d  %d kbps  ",
                       size.width, size.height, fps, dropped, kbps) + (remuxed ? "remux" : "direct")
        if !probeInfo.isEmpty { stats += "\n" + probeInfo }
    }

    /// Save position ("pos|dur|ts") + keep the Continue Watching entry fresh (with the ts the
    /// server sorts by) and the scoped cw: add stamp so removals merge across devices.
    func savePos(_ pos: Int, _ dur: Int, push: Bool) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var ps = session.pstate()
        var positions = ps["positions"] as? [String: Any] ?? [:]
        positions[posKey()] = "\(pos)|\(dur)|\(now)"
        ps["positions"] = positions
        var cw = ps["continue"] as? [[String: Any]] ?? []
        var entry = request.meta.dict
        entry["ts"] = now
        if let i = cw.firstIndex(where: { $0["id"] as? String == request.meta.id }) {
            cw.remove(at: i)
        } else {
            var added = ps["addedTs"] as? [String: Any] ?? [:]
            added["cw:" + request.meta.id] = now
            ps["addedTs"] = added
        }
        cw.insert(entry, at: 0)
        ps["continue"] = Array(cw.prefix(12))
        // per-title last-episode pointer — resume-on-tap lands on the right episode
        if request.season != nil {
            var cwlast = ps["cwlast"] as? [String: Any] ?? [:]
            cwlast[request.meta.id] = posKey()
            ps["cwlast"] = cwlast
        }
        session.setPstate(ps, push: push)
    }

    /// Position where the episode is "basically over" (credits rolling): last subtitle cue
    /// + 2s when plausible (15s–5min lead) → learned credits from /player/resume → 90s
    /// default, floored at 80% of the runtime (Android finishPointMs/currentLeadMs).
    func finishPointMs(_ dur: Int) -> Int {
        let lastCue = subCues.map(\.to).max() ?? 0
        let subsLead = lastCue > 0 ? dur - lastCue - 2000 : -1
        let lead: Int
        if (15_000...300_000).contains(subsLead) { lead = subsLead }
        else if windows.credits > 0 && windows.credits < dur { lead = dur - windows.credits }
        else { lead = 90_000 }
        // CAP (AJ Sep 28, parity w/ TV 2.0.123): finished by 90% (movies) / 92% (shows) so a
        // long-credits movie marks watched + leaves Continue Watching without sitting through credits.
        let cap = dur * (request.season != nil ? 92 : 90) / 100
        return min(max(dur - max(lead, 0), dur * 80 / 100), cap)
    }

    /// NOT watched if you barely played it: starting near the top + <2 min played is never
    /// a finish (the false-watched@4% fix) — the only legit short sit-down is a real
    /// resume near the end (sessionStart ≥ 2min).
    var qualifiesWatched: Bool {
        durMs > 0 && posMs >= finishPointMs(durMs) &&
        (posMs - sessionStartMs >= 120_000 || sessionStartMs >= 120_000)
    }

    /// Mark watched + clear resume (with pos: tombstone so the clear survives the union
    /// merge). Movies also leave Continue Watching — shows stay ("watched E5" still means
    /// "resume the series").
    func finishEpisode() {
        guard !finishedHandled, qualifiesWatched else { return }
        finishedHandled = true
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var ps = session.pstate()
        var positions = ps["positions"] as? [String: Any] ?? [:]
        var added = ps["addedTs"] as? [String: Any] ?? [:]
        var removed = ps["removedTs"] as? [String: Any] ?? [:]
        let key = posKey()
        positions.removeValue(forKey: key)
        removed["pos:" + key] = now
        ps["positions"] = positions
        var ids = ps["watchedIds"] as? [String] ?? []
        if request.season != nil {
            if !ids.contains(key) { ids.append(key) }
            added["wt:" + key] = now
            // advance Continue Watching to the next episode with a fresh (blank) bar when we know it
            // — parity w/ TV 2.0.126 (AJ Sep 28): resume the NEXT episode, not replay the finished one.
            if let nx = nextEp {
                var cwl = ps["cwlast"] as? [String: Any] ?? [:]
                cwl[request.meta.id] = "\(request.meta.id):\(nx.season):\(nx.episode)"
                ps["cwlast"] = cwl
            }
            // WATCHED SHELF (parity w/ TV 2.0.126): a show earns Library→Watched only when the
            // episode just finished is the LAST one that exists (nothing after it) — handles
            // 7/8-with-finale-pending and jumping in mid-series. Uses the cached episode list.
            if let vids = MetaCache.shared.cached(request.meta.id) {
                let eps = vids.compactMap { v -> (Int, Int)? in
                    guard let s = v["season"] as? Int, s > 0, let e = v["episode"] as? Int else { return nil }
                    return (s, e)
                }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
                let cs = request.season ?? 0, ce = request.episode ?? 0
                if eps.last.map({ $0.0 == cs && $0.1 == ce }) == true {
                    var wt = ps["watchedTitles"] as? [[String: Any]] ?? []
                    if !wt.contains(where: { $0["id"] as? String == request.meta.id }) {
                        wt.insert(request.meta.dict, at: 0)
                    }
                    ps["watchedTitles"] = wt
                }
            }
        } else {
            if !ids.contains(request.meta.id) { ids.append(request.meta.id) }
            added["wt:" + request.meta.id] = now
            var wt = ps["watchedTitles"] as? [[String: Any]] ?? []
            if !wt.contains(where: { $0["id"] as? String == request.meta.id }) {
                wt.insert(request.meta.dict, at: 0)
            }
            ps["watchedTitles"] = wt
            var cw = ps["continue"] as? [[String: Any]] ?? []
            cw.removeAll { $0["id"] as? String == request.meta.id }
            ps["continue"] = cw
            removed["cw:" + request.meta.id] = now
            session.clearServerResume(id: request.meta.id)
        }
        ps["watchedIds"] = ids
        ps["addedTs"] = added
        ps["removedTs"] = removed
        session.setPstate(ps)
        session.reportProgress(id: request.meta.id, season: request.season,
                               episode: request.episode, pos: posMs, dur: durMs)
    }

    func playRemux(fromMs: Int) {
        guard !API.serviceBase.isEmpty else { failed = true; return }
        let b64 = API.b64url(playURL.absoluteString)
        // /webhls, NOT /webplay: AVFoundation can't consume the piped fragmented-MP4 remux
        // (the exact reason the HLS lane exists — ck-web routes iOS the same way). 302 →
        // event playlist, video stream-copied, audio → AAC.
        guard let remux = URL(string: API.serviceBase + "/webhls?u=\(b64)&t=\(fromMs / 1000)") else { return }
        remuxed = true; seeking = true
        remuxBaseMs = fromMs
        // the remux really begins at the KEYFRAME at-or-before fromMs (t=873 → 868.2) — snap
        // the clock base to the real start (same /webplay/start snap the web player does) or
        // subtitles + position drift by up to a whole GOP after every seek/fallback.
        Task { @MainActor in
            if let r = try? await API.json("/webplay/start?u=\(b64)&t=\(fromMs / 1000)"),
               let real = r["start"] as? Double, real.isFinite {
                remuxBaseMs = Int(real * 1000)
            }
        }
        let item = AVPlayerItem(url: remux)
        player.replaceCurrentItem(with: item)
        observeItem(item)
        player.play()
        Task {
            try? await Task.sleep(for: .seconds(8))
            if item.status == .failed { failed = true }
        }
    }

    func seek(ms: Int) {
        let target = max(0, ms)
        if remuxed {
            // inside what ffmpeg has ALREADY transcoded → instant in-playlist seek; only a
            // jump beyond the live edge reopens the session at the target (web parity)
            let local = target - remuxBaseMs
            let transcoded = Int(((player.currentItem?.duration.seconds ?? 0).isFinite
                                  ? (player.currentItem?.duration.seconds ?? 0) : 0) * 1000)
            if local >= 0 && transcoded > 0 && local < transcoded - 4000 {
                player.seek(to: CMTime(seconds: Double(local) / 1000, preferredTimescale: 1000),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                posMs = target
                return
            }
            playRemux(fromMs: target)
            posMs = target
            return
        }
        // seeking a not-ready item does nothing and can wedge playback — stash it and apply
        // when the item is ready (handled in the open loop / status poll)
        guard let item = player.currentItem, item.status == .readyToPlay else {
            pendingSeekMs = target; posMs = target; return
        }
        if abs(target - posMs) > 4000 { seeking = true }   // big jump → loading card, not black
        posMs = target
        player.seek(to: CMTime(seconds: Double(target) / 1000, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: subtitles

    /// Ranked track list (Android subtitleOptions): English-best-first, up to 12.
    func rankSubtitles(_ subs: [[String: Any]]) -> [[String: Any]] {
        func score(_ s: [String: Any]) -> Int {
            let lang = (s["lang"] as? String ?? "").lowercased()
            let name = (s["name"] as? String ?? s["id"] as? String ?? "").lowercased()
            var sc = 0
            if lang.hasPrefix("en") || name.contains("english") { sc += 100 }
            if name.contains("sdh") || name.contains("hearing") { sc -= 5 }
            if name.contains("forced") { sc -= 20 }
            return sc
        }
        return Array(subs.sorted { score($0) > score($1) }.prefix(12))
    }

    /// OpenSubtitles v3 extras (Android Ck.v3Subs): the default subtitle service Android
    /// always queries — without it the iOS picker missed the whole "English (OpenSubtitles
    /// N)" list (AJ: "I don't have the same English srt options like on Android"). English
    /// only, capped at 12, deduped against addon-delivered subs, 1.5s so it can never
    /// delay first frame.
    func mergeV3Subs() async {
        guard !isLive, !placeholder else { return }
        let id = request.season != nil ? "\(request.meta.id):\(request.season!):\(request.episode ?? 1)" : request.meta.id
        let kind = request.season != nil ? "series" : "movie"
        let task = Task { () -> [[String: Any]] in
            guard let u = URL(string: "https://opensubtitles-v3.strem.io/subtitles/\(kind)/\(id).json"),
                  let (d, _) = try? await URLSession.shared.data(from: u),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let subs = j["subtitles"] as? [[String: Any]] else { return [] }
            var out: [[String: Any]] = []
            for o in subs where (o["lang"] as? String) == "eng" {
                guard let su = o["url"] as? String, !su.isEmpty else { continue }
                out.append(["url": su, "lang": "English (OpenSubtitles \(out.count + 1))"])
                if out.count >= 12 { break }
            }
            return out
        }
        let extra = (try? await withThrowingTaskGroup(of: [[String: Any]].self) { g -> [[String: Any]] in
            g.addTask { await task.value }
            g.addTask { try await Task.sleep(for: .milliseconds(1500)); task.cancel(); return [] }
            let first = try await g.next() ?? []
            g.cancelAll()
            return first
        }) ?? []
        guard !extra.isEmpty else { return }
        let have = Set(subTracks.compactMap { $0["url"] as? String })
        let fresh = extra.filter { !have.contains($0["url"] as? String ?? "") }
        if !fresh.isEmpty {
            subTracks = Array((subTracks + fresh).prefix(24))
            if subIndex < 0, session.pref("subLang", "off") != "off", subTracks.count == fresh.count { pickSub(0) }
        }
    }

    func loadSubtitles() async {
        guard session.pref("subLang", "off") != "off", !placeholder else { subIndex = -1; return }
        if subTracks.isEmpty, let base = session.addonBase(), !isLive {
            // the addon attaches ranked subtitle files to each stream response — refetch the
            // stream list for this item and take this stream's list
            let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let type = request.season != nil ? "series" : "movie"
            if let r = try? await API.json("/stream/\(type)/\(posKey()).json?u=\(u)", base: base),
               let streams = r["streams"] as? [[String: Any]],
               let mine = streams.first(where: { $0["url"] as? String == request.url.absoluteString }) ?? streams.first,
               let subs = mine["subtitles"] as? [[String: Any]] {
                subTracks = rankSubtitles(subs)
            }
        }
        guard !subTracks.isEmpty else { return }
        pickSub(0)
    }

    /// Apply a track live (Android applySubtitle): -1 = off; flashes the label.
    func pickSub(_ i: Int) {
        subIndex = i
        guard i >= 0, i < subTracks.count else {
            subCues = []; currentCue = ""; flashLabel("Subtitles off"); return
        }
        let t = subTracks[i]
        flashLabel("Subtitles: \(t["lang"] as? String ?? t["name"] as? String ?? "on")")
        subxTask?.cancel(); subxTask = nil
        if let idx = t["embedded"] as? Int {
            subCues = []
            streamEmbedded(index: idx, track: i, fromMs: max(0, posMs - 30_000))
            return
        }
        Task {
            guard let surl = t["url"] as? String, let u = URL(string: surl),
                  let data = try? await URLSession.shared.data(from: u).0,
                  let text = String(data: data, encoding: .utf8) else { return }
            if subIndex == i { subCues = SubCue.parse(text) }
        }
    }

    /// Embedded subtitle track via /webplay/subx (IOS_CONTRACTS §4): ffmpeg live-converts to
    /// WebVTT on the file's absolute clock, streamed progressively — cues are appended as
    /// blocks arrive so the first lines show within seconds.
    func streamEmbedded(index: Int, track: Int, fromMs: Int) {
        guard !API.serviceBase.isEmpty,
              let url = URL(string: API.serviceBase + "/webplay/subx?u=\(API.b64url(playURL.absoluteString))&i=\(index)&t=\(fromMs / 1000)")
        else { return }
        subxFrom = fromMs
        subxTask = Task {
            var req = URLRequest(url: url); req.timeoutInterval = 600
            guard let res = try? await URLSession.shared.bytes(for: req) else { return }
            let bytes = res.0
            var block: [String] = []
            do {
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.isEmpty {
                        let cues = SubCue.parse(block.joined(separator: "\n"))
                        block = []
                        if !cues.isEmpty { await MainActor.run { if subIndex == track { subCues += cues } } }
                    } else { block.append(line) }
                }
            } catch { }
            let tail = SubCue.parse(block.joined(separator: "\n"))
            if !tail.isEmpty { await MainActor.run { if subIndex == track { subCues += tail } } }
        }
    }

    /// GET /webplay/probe → duration / codecs / embedded text-subtitle streams (§4). Embedded
    /// tracks join the addon's ranked list; the codec line feeds the stats overlay.
    func probeMedia() async {
        guard !API.serviceBase.isEmpty,
              let r = try? await API.json("/webplay/probe?u=\(API.b64url(playURL.absoluteString))"),
              (r["duration"] as? Double ?? Double(r["duration"] as? Int ?? 0)) > 0 else { return }
        let dur = r["duration"] as? Double ?? Double(r["duration"] as? Int ?? 0)
        probeInfo = "\(r["vcodec"] as? String ?? "?") / \(r["acodec"] as? String ?? "?") · \(Int(dur / 60)) min"
        probedDurMs = Int(dur * 1000)
        if remuxed { durMs = probedDurMs }
        var added: [[String: Any]] = []
        for s in r["subs"] as? [[String: Any]] ?? [] {
            guard let i = s["i"] as? Int else { continue }
            let lang = s["lang"] as? String ?? "und"
            var name = "Embedded · " + (s["title"] as? String ?? lang)
            if s["forced"] as? Bool == true { name += " (forced)" }
            if s["hi"] as? Bool == true { name += " (SDH)" }
            added.append(["lang": lang, "name": name, "embedded": i])
        }
        guard !added.isEmpty else { return }
        subTracks = Array(rankSubtitles(subTracks + added).prefix(12))
        // nothing picked yet (no addon subs) → the best embedded track becomes the default
        if subIndex < 0, session.pref("subLang", "off") != "off", !subTracks.isEmpty { pickSub(0) }
    }

    // MARK: placeholder hot-swap (IOS_CONTRACTS §5)

    /// Re-request the stream list every ~18s while the clip loops; the first non-placeholder
    /// stream is hot-swapped in and the normal UI comes back.
    func startPlaceholderPoll() {
        placeholderPoll?.cancel()
        placeholderPoll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, let base = session.addonBase(), !request.streamPath.isEmpty else { return }
                let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                guard let r = try? await API.json(request.streamPath + "?u=\(u)", base: base),
                      let list = r["streams"] as? [[String: Any]],
                      let real = list.first(where: { !PlayRequest.isPlaceholder($0) && ($0["url"] as? String) != nil })
                else { continue }
                await MainActor.run { hotSwap(real) }
                return
            }
        }
    }

    func hotSwap(_ s: [String: Any]) {
        guard let us = s["url"] as? String, let url = URL(string: us) else { return }
        swapped = s
        placeholder = false
        firstFrame = false
        let w = PlayerWindows(stream: s)
        if w.hasWindows { windows.adopt(w) }
        subTracks = rankSubtitles(s["subtitles"] as? [[String: Any]] ?? [])
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeItem(item)
        player.play()
        flashLabel("Now playing the full file")
        Task {
            await probeMedia()
            if subIndex < 0, !subTracks.isEmpty, session.pref("subLang", "off") != "off" { pickSub(0) }
        }
    }

    // MARK: next episode

    /// The episode after this one from the REAL list — crosses seasons (Android nextEpisode()).
    func computeNextEpisode() -> Episode? {
        guard let s = request.season, let e = request.episode else { return nil }
        let list = allEpisodes.filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        if let i = list.firstIndex(where: { $0.season == s && $0.episode == e }), i + 1 < list.count {
            let n = list[i + 1]
            return n.unaired ? nil : n
        }
        if list.isEmpty {   // no list handed over: same-season e+1 (legacy behavior)
            var o: [String: Any] = ["id": "\(request.meta.id):\(s):\(e + 1)", "season": s, "episode": e + 1]
            o["name"] = "Episode \(e + 1)"
            return Episode(o)
        }
        return nil
    }

    func resolveStream(_ ep: Episode) async -> PlayRequest? {
        guard let base = session.addonBase() else { return nil }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = try? await API.json("/stream/series/\(ep.id).json?u=\(u)", base: base),
              let st = (r["streams"] as? [[String: Any]])?.first,
              let us = st["url"] as? String, let url = URL(string: us) else { return nil }
        var req = PlayRequest(url: url, meta: request.meta, season: ep.season, episode: ep.episode)
        req.episodes = allEpisodes
        req.streamWindows = PlayerWindows(stream: st)
        req.subtitles = st["subtitles"] as? [[String: Any]] ?? []
        return req
    }

    /// Prefetch 5 min before the end (Android prefetchNext) so the advance is instant.
    func prefetchNext(_ ep: Episode) async {
        guard nextReq == nil else { return }
        nextReq = await resolveStream(ep)
    }

    func playEpisode(_ ep: Episode, idle: Int) async {
        var req = (nextReq?.episode == ep.episode && nextReq?.season == ep.season) ? nextReq : nil
        if req == nil { req = await resolveStream(ep) }
        guard var r = req else { close(); return }
        r.idleEps = idle
        await reloadInPlace(r)
    }

    /// Swap the loaded episode without opening a new player screen (Android = same activity,
    /// new media). Tears the current session down, resets per-episode state, reopens.
    func reloadInPlace(_ r: PlayRequest) async {
        // save where we were leaving before we drop the old item
        if !isLive && !placeholder && durMs > 0 {
            savePos(posMs, durMs, push: true)
        }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        player.pause(); player.replaceCurrentItem(with: nil)
        // reset per-episode state
        reqOverride = r
        firstFrame = false; failed = false; remuxed = false; remuxBaseMs = 0
        posMs = 0; durMs = 0; probedDurMs = 0; pendingSeekMs = -1
        subCues = []; currentCue = ""; subTracks = []; subIndex = -1
        nextEp = nil; nextReq = nil; showNextUp = false; nextUpDismissed = false
        finishedHandled = false; startStamped = false; controlsVisible = true
        windows = PlayerWindows()
        await start()
    }

    func onEnded() {
        if placeholder { seek(ms: 0); player.play(); return }   // loop the clip until the real file lands
        finishEpisode()
        // Popped out: the next episode opens as a new player screen, which can't re-enter PiP
        // from the background — so close the pop-out and leave Next-Up waiting for the return.
        if pip.active {
            pip.stop()
            if nextEp != nil { showNextUp = true; controlsVisible = true }
            return
        }
        guard !isLive, session.pref("autoplayNext", true), request.season != nil,
              let ep = nextEp else { close(); return }
        // 2 consecutive fully-input-less auto-advances → ask before rolling a third
        let idle = epTouched ? 0 : request.idleEps + 1
        if idle >= 2 {
            showNextUp = false
            showStillWatching = true
            Task {   // no answer in 5 minutes = stop playback and exit
                try? await Task.sleep(for: .seconds(300))
                if showStillWatching { close() }
            }
        } else {
            Task { await playEpisode(ep, idle: idle) }
        }
    }

    func stop() {
        Platform.keepAwake(false)
        Platform.lockLandscape(false)
        let pos = max(remuxBaseMs + Self.safeMs(player.currentTime().seconds), posMs)
        posMs = pos
        if remuxed { if probedDurMs > 0 { durMs = probedDurMs } }
        else if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { durMs = Int(d * 1000) }
        if !isLive && !placeholder && !finishedHandled {
            if qualifiesWatched {
                finishEpisode()
            } else if pos > 5000 {
                savePos(pos, durMs, push: true)
                // one tiny POST per sit-down (Android: exit / episode switch / finish)
                session.reportProgress(id: request.meta.id, season: request.season,
                                       episode: request.episode, pos: pos, dur: durMs)
            }
        }
        pip.stop()
        hideTask?.cancel(); hideTask = nil
        placeholderPoll?.cancel(); placeholderPoll = nil
        subxTask?.cancel(); subxTask = nil
        if let t = timeObserver { player.removeTimeObserver(t) }
        timeObserver = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        session.homeStale += 1   // Home re-pulls + repaints the Continue row on return
    }
}

// MARK: - pieces

struct SkipPill: View {
    let text: String
    var focus: FocusState<PlayerView.PFocus?>.Binding? = nil
    let action: () -> Void
    init(text: String, focus: FocusState<PlayerView.PFocus?>.Binding? = nil, action: @escaping () -> Void) {
        self.text = text; self.focus = focus; self.action = action
    }
    var body: some View {
        if let focus { pill.focused(focus, equals: .skip) } else { pill }
    }
    private var pill: some View {
        Button(action: action) {
            Text(text).font(.subheadline.bold())
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white.opacity(0.92), in: Capsule())
                .foregroundStyle(.black)
        }
    }
}

/// Seek-step control (Android seekStepSec applied to the seek controls): ⟲10 / ⟳10.
struct SeekButton: View {
    let icon: String, label: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: icon).font(.title2)
                Text(label).font(.system(size: 9, weight: .bold)).offset(y: 1)
            }
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.5), in: Circle())
            .foregroundStyle(.white)
        }
    }
}

/// Pulse animation for the loading-screen art.
struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0.45).scaleEffect(on ? 1 : 0.94)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Subtitle side panel (Android showSubtitleSidePanel): stays open with LIVE apply — track
/// list (Off first), size incl. Tiny, background, outline, position.
struct SubtitleLookSheet: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Look") {
                    PrefPicker(label: "Size", key: "subScale", def: 1.0,
                               options: [(0.6, "Tiny"), (0.8, "Small"), (1.0, "Normal"), (1.3, "Large"), (1.6, "Huge")])
                    PrefToggle(label: "Background", key: "subBg", def: false)
                    PrefToggle(label: "Outline", key: "subOutline", def: true)
                    PrefPicker(label: "Position", key: "subPos", def: "normal",
                               options: [("normal", "Normal"), ("raised", "Raised"), ("high", "High")])
                }
            }
            .navigationTitle("Subtitle style").ckInlineTitle()
        }
    }
}

struct SubtitlePanel: View {
    @EnvironmentObject var session: Session
    let tracks: [[String: Any]]
    @Binding var index: Int
    let onPick: (Int) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Track") {
                    Button { onPick(-1) } label: {
                        HStack { Text("Off"); Spacer(); if index < 0 { Image(systemName: "checkmark").foregroundStyle(Theme.accent) } }
                    }
                    ForEach(tracks.indices, id: \.self) { i in
                        Button { onPick(i) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(tracks[i]["lang"] as? String ?? "Track \(i + 1)")
                                    if let n = tracks[i]["name"] as? String ?? tracks[i]["id"] as? String {
                                        Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if index == i { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                }
                Section("Look") {
                    PrefPicker(label: "Size", key: "subScale", def: 1.0,
                               options: [(0.6, "Tiny"), (0.8, "Small"), (1.0, "Normal"), (1.3, "Large"), (1.6, "Huge")])
                    PrefToggle(label: "Background", key: "subBg", def: false)
                    PrefToggle(label: "Outline", key: "subOutline", def: true)
                    PrefPicker(label: "Position", key: "subPos", def: "normal",
                               options: [("normal", "Normal"), ("raised", "Raised"), ("high", "High")])
                    SubtitlePreview()
                }
            }
            .navigationTitle("Subtitles")
            .ckInlineTitle()
        }
    }
}

/// In-player episode panel (Android toggleEpisodePanel): season tabs + episode strip, the
/// current episode highlighted and scrolled into view.
struct EpisodePanel: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let episodes: [Episode]
    let currentId: String
    let onPick: (Episode) -> Void
    @State private var season = 0
    private var seasons: [Int] { Array(Set(episodes.map(\.season))).filter { $0 > 0 }.sorted() }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(seasons, id: \.self) { s in
                            Button("Season \(s)") { season = s }
                                .buttonStyle(.bordered).tint(s == season ? Theme.accent : .gray)
                        }
                    }.padding(.horizontal, Platform.gutter)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }) { ep in
                                Button { onPick(ep) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        AsyncImage(url: URL(string: ep.thumb ?? "")) { img in
                                            img.resizable().aspectRatio(contentMode: .fill)
                                        } placeholder: { Theme.card }
                                        .frame(width: 150, height: 84).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(Theme.accent, lineWidth: ep.id == currentId ? 2 : 0))
                                        Text("E\(ep.episode) · \(ep.name)").font(.caption).lineLimit(1)
                                            .frame(width: 150, alignment: .leading)
                                            .foregroundStyle(ep.id == currentId ? Theme.accent : .primary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .id(ep.id)
                            }
                        }.padding(.horizontal, Platform.gutter)
                    }
                    .onAppear { proxy.scrollTo(currentId, anchor: .center) }
                }
                Spacer()
            }
            .padding(.top, 10)
            .background(Theme.bg)
            .navigationTitle(meta.name)
            .ckInlineTitle()
            .onAppear {
                season = episodes.first { $0.id == currentId }?.season ?? seasons.first ?? 0
            }
        }
    }
}

// Native AirPlay route button — casts the actual video to an Apple TV / AirPlay device (reliable,
// unlike the web transcode). Also lists other output routes. Apple TV itself is the AirPlay
// receiver, so tvOS shows nothing here.
#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayButton: View { var body: some View { EmptyView() } }
#endif

// Minimal SRT/VTT cue parser — covers the addon's ranked subtitle files.
struct SubCue {
    let from: Int, to: Int, text: String
    static func parse(_ raw: String) -> [SubCue] {
        var cues: [SubCue] = []
        let blocks = raw.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n").map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2,
                  let f = ms(parts[0]), let t = ms(parts[1]) else { continue }
            let text = lines.dropFirst(ti + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !text.isEmpty { cues.append(SubCue(from: f, to: t, text: text)) }
        }
        return cues
    }
    private static func ms(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: " ").first ?? ""
        let p = t.components(separatedBy: ":")
        guard p.count >= 2 else { return nil }
        let sec = Double(p.last ?? "0") ?? 0
        let min = Int(p[p.count - 2]) ?? 0
        let hr = p.count > 2 ? (Int(p[p.count - 3]) ?? 0) : 0
        return hr * 3_600_000 + min * 60_000 + Int(sec * 1000)
    }
}
