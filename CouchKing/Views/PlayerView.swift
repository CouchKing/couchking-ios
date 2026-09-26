import SwiftUI
import AVKit

// Player — Android parity: /webplay remux fallback, resume, Skip Intro / Skip Recap /
// after-credits jump, learned credits point, autoplay-next, external subtitles overlay,
// progress heartbeat (instant start-stamp, 30s beats, 90s pushes, zombie guard),
// mark-watched-on-finish with credits-from-subtitles, "Are you still watching?".
struct PlayerView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let request: PlayRequest
    @State private var player = AVPlayer()
    @State private var windows = PlayerWindows()
    @State private var posMs = 0
    @State private var durMs = 0
    @State private var subCues: [SubCue] = []
    @State private var currentCue = ""
    @State private var nextEpisode: PlayRequest?
    // ---- watched tracking + account heartbeat (Android PlayerActivity ticker) ----
    @State private var sessionStartMs = 0     // where this sit-down began (resume point)
    @State private var beatCount = 0
    @State private var lastBeatPos = -1       // zombie guard: only a MOVING position beats
    @State private var startStamped = false
    @State private var firstReported = false
    @State private var finishedHandled = false
    // ---- "Are you still watching?" — 2 input-less auto-advances arm the modal ----
    @State private var epTouched = false
    @State private var showStillWatching = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    init(request: PlayRequest) { self.request = request }
    // legacy call sites (movie stream list) still hand us a bare url
    init(url: URL, meta: Meta) {
        self.request = PlayRequest(url: url, meta: meta, season: nil, episode: nil)
    }

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .ignoresSafeArea()
            overlay
            if showStillWatching { stillWatchingCard }
        }
        .background(.black)
        // any tap during an episode = someone's there → the idle chain resets
        .simultaneousGesture(TapGesture().onEnded { epTouched = true })
        .onAppear { Task { await start() } }
        .onDisappear { stop() }
        .fullScreenCover(item: $nextEpisode) { req in PlayerView(request: req) }
    }

    @ViewBuilder private var overlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
            }
            .padding()
            Spacer()
            if !currentCue.isEmpty {
                Text(currentCue)
                    .font(.system(size: 17 * session.pref("subScale", 1.0)))
                    .multilineTextAlignment(.center)
                    .padding(6)
                    .background(session.pref("subBg", true) ? .black.opacity(0.6) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 8)
            }
            HStack {
                Spacer()
                skipButton
            }
            .padding(.bottom, 40)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var skipButton: some View {
        if windows.recapFrom > 0, posMs >= windows.recapFrom, posMs < windows.recapTo {
            SkipPill(text: "Skip Recap") { epTouched = true; seek(ms: windows.recapTo) }
        } else if windows.introFrom > 0, posMs >= windows.introFrom, posMs < windows.introTo {
            SkipPill(text: "Skip Intro") { epTouched = true; seek(ms: windows.introTo) }
        } else if let ac = windows.afterCredits.first(where: { posMs < $0[0] && $0[0] - posMs < 600_000 }),
                  windows.credits > 0, posMs >= windows.credits {
            SkipPill(text: "After credits ▶") { epTouched = true; seek(ms: ac[0]) }
        }
    }

    /// Crown + Keep watching / I'm done. BACK-out = dismiss; no answer for 5 minutes =
    /// playback stops and the player exits (Android showStillWatching).
    private var stillWatchingCard: some View {
        VStack(spacing: 14) {
            Text("👑").font(.system(size: 40))
            Text("Are you still watching?").font(.title3.bold())
            Button {
                showStillWatching = false
                if let s = request.season, let e = request.episode {
                    advance(idle: 0, season: s, episode: e)
                } else { dismiss() }
            } label: {
                Text("Keep watching").font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button("I'm done") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }

    private func start() async {
        // keep-screen-on while playing (Android FLAG_KEEP_SCREEN_ON fix, Sep 18)
        UIApplication.shared.isIdleTimerDisabled = true
        windows = await PlayerWindows.fetch(session: session, id: request.meta.id,
                                            season: request.season, episode: request.episode)
        let item = AVPlayerItem(url: request.url)
        player.replaceCurrentItem(with: item)
        // resume: local positions map first (synced), server pos as fallback
        let local = ((session.pstate()["positions"] as? [String: Any])?[posKey()] as? String)?
            .split(separator: "|").first.flatMap { Int($0) } ?? 0
        let resume = max(local, windows.resumeMs)
        if resume > 120_000 { seek(ms: resume); sessionStartMs = resume }
        player.play()
        // remux fallback for containers AVPlayer can't open
        Task {
            try? await Task.sleep(for: .seconds(4))
            if item.status == .failed { playRemux(fromMs: resume) }
        }
        // position ticker drives skip buttons + subtitle cues + the account heartbeat
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10),
                                                      queue: .main) { t in
            Task { @MainActor in
                posMs = Int(t.seconds * 1000)
                currentCue = subCues.first(where: { posMs >= $0.from && posMs <= $0.to })?.text ?? ""
                heartbeat()
            }
        }
        await loadSubtitles()
        observeEnd()
    }

    private func posKey() -> String {
        request.season != nil ? "\(request.meta.id):\(request.season!):\(request.episode!)" : request.meta.id
    }

    /// Android ticker parity: instant start-stamp (the moment playback starts, stamp + push
    /// so other devices resume-target immediately), first report ~20s in then every 30s,
    /// local resume bar every 30s, account blob every 90s — all gated on a MOVING position
    /// (the zombie guard: a stick frozen "playing" for 26h must never pin CW everywhere).
    private func heartbeat() {
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { durMs = Int(d * 1000) }
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
        if beatCount % 90 == 0 && moved { session.push() }
    }

    /// Save position ("pos|dur|ts") + keep the Continue Watching entry fresh, with the
    /// scoped cw: add stamp so removals merge correctly across devices.
    private func savePos(_ pos: Int, _ dur: Int, push: Bool) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var ps = session.pstate()
        var positions = ps["positions"] as? [String: Any] ?? [:]
        positions[posKey()] = "\(pos)|\(dur)|\(now)"
        ps["positions"] = positions
        var cw = ps["continue"] as? [[String: Any]] ?? []
        if !cw.contains(where: { $0["id"] as? String == request.meta.id }) {
            cw.insert(["id": request.meta.id, "type": request.meta.type,
                       "name": request.meta.name, "poster": request.meta.poster ?? ""], at: 0)
            var added = ps["addedTs"] as? [String: Any] ?? [:]
            added["cw:" + request.meta.id] = now
            ps["addedTs"] = added
        }
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
    private func finishPointMs(_ dur: Int) -> Int {
        let lastCue = subCues.map(\.to).max() ?? 0
        let subsLead = lastCue > 0 ? dur - lastCue - 2000 : -1
        let lead: Int
        if (15_000...300_000).contains(subsLead) { lead = subsLead }
        else if windows.credits > 0 && windows.credits < dur { lead = dur - windows.credits }
        else { lead = 90_000 }
        return max(dur - max(lead, 0), dur * 80 / 100)
    }

    /// NOT watched if you barely played it: starting near the top + <2 min played is never
    /// a finish (the false-watched@4% fix) — the only legit short sit-down is a real
    /// resume near the end (sessionStart ≥ 2min).
    private var qualifiesWatched: Bool {
        durMs > 0 && posMs >= finishPointMs(durMs) &&
        (posMs - sessionStartMs >= 120_000 || sessionStartMs >= 120_000)
    }

    /// Mark watched + clear resume (with pos: tombstone so the clear survives the union
    /// merge). Movies also leave Continue Watching — shows stay ("watched E5" still means
    /// "resume the series").
    private func finishEpisode() {
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
        } else {
            if !ids.contains(request.meta.id) { ids.append(request.meta.id) }
            added["wt:" + request.meta.id] = now
            var wt = ps["watchedTitles"] as? [[String: Any]] ?? []
            if !wt.contains(where: { $0["id"] as? String == request.meta.id }) {
                wt.insert(["id": request.meta.id, "type": request.meta.type,
                           "name": request.meta.name, "poster": request.meta.poster ?? ""], at: 0)
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

    private func playRemux(fromMs: Int) {
        let b64 = request.url.absoluteString.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let remux = URL(string: API.serviceBase + "/webplay?u=\(b64)&t=\(fromMs / 1000)") else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: remux))
        player.play()
    }

    private func seek(ms: Int) {
        player.seek(to: CMTime(seconds: Double(ms) / 1000, preferredTimescale: 1000))
    }

    private func loadSubtitles() async {
        guard session.pref("subLang", "en") != "off" else { return }
        // the addon attaches ranked subtitle files to each stream response — refetch the
        // stream list for this item and take the top matching-language subtitle
        guard let addon = session.addons.first else { return }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let sid = posKey()
        let type = request.season != nil ? "series" : "movie"
        guard let r = try? await API.json("/stream/\(type)/\(sid).json?u=\(u)", base: addon.url),
              let streams = r["streams"] as? [[String: Any]],
              let mine = streams.first(where: { $0["url"] as? String == request.url.absoluteString }) ?? streams.first,
              let subs = mine["subtitles"] as? [[String: Any]],
              let first = subs.first(where: { ($0["lang"] as? String ?? "").hasPrefix(session.pref("subLang", "en")) }) ?? subs.first,
              let surl = first["url"] as? String, let u2 = URL(string: surl),
              let data = try? await URLSession.shared.data(from: u2).0,
              let text = String(data: data, encoding: .utf8) else { return }
        subCues = SubCue.parse(text)
    }

    private func observeEnd() {
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: player.currentItem,
                                                             queue: .main) { _ in
            Task { @MainActor in onEnded() }
        }
    }

    private func onEnded() {
        finishEpisode()
        guard session.pref("autoplayNext", true),
              let s = request.season, let e = request.episode else { dismiss(); return }
        // 2 consecutive fully-input-less auto-advances → ask before rolling a third
        let idle = epTouched ? 0 : request.idleEps + 1
        if idle >= 2 {
            showStillWatching = true
            Task {   // no answer in 5 minutes = stop playback and exit
                try? await Task.sleep(for: .seconds(300))
                if showStillWatching { dismiss() }
            }
        } else {
            advance(idle: idle, season: s, episode: e)
        }
    }

    private func advance(idle: Int, season s: Int, episode e: Int) {
        Task {
            guard let addon = session.addons.first else { dismiss(); return }
            let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let next = "\(request.meta.id):\(s):\(e + 1)"
            if let r = try? await API.json("/stream/series/\(next).json?u=\(u)", base: addon.url),
               let st = (r["streams"] as? [[String: Any]])?.first,
               let us = st["url"] as? String, let url = URL(string: us) {
                nextEpisode = PlayRequest(url: url, meta: request.meta, season: s, episode: e + 1,
                                          idleEps: idle)
            } else { dismiss() }
        }
    }

    private func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        let pos = max(Int(player.currentTime().seconds * 1000), posMs)
        posMs = pos
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { durMs = Int(d * 1000) }
        if !finishedHandled {
            if qualifiesWatched {
                finishEpisode()
            } else if pos > 5000 {
                savePos(pos, durMs, push: true)
                // one tiny POST per sit-down (Android: exit / episode switch / finish)
                session.reportProgress(id: request.meta.id, season: request.season,
                                       episode: request.episode, pos: pos, dur: durMs)
            }
        }
        if let t = timeObserver { player.removeTimeObserver(t) }
        timeObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct SkipPill: View {
    let text: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.subheadline.bold())
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white.opacity(0.92), in: Capsule())
                .foregroundStyle(.black)
        }
    }
}

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
