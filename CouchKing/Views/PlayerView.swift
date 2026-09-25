import SwiftUI
import AVKit

// Player — Android parity: /webplay remux fallback, resume, Skip Intro / Skip Recap /
// after-credits jump, learned credits point, autoplay-next, external subtitles overlay
// (streams carry ranked English subs from the addon), per-profile settings applied.
struct PlayerView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let request: PlayRequest
    @State private var player = AVPlayer()
    @State private var windows = PlayerWindows()
    @State private var posMs = 0
    @State private var subCues: [SubCue] = []
    @State private var currentCue = ""
    @State private var nextEpisode: PlayRequest?

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
        }
        .background(.black)
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
            SkipPill(text: "Skip Recap") { seek(ms: windows.recapTo) }
        } else if windows.introFrom > 0, posMs >= windows.introFrom, posMs < windows.introTo {
            SkipPill(text: "Skip Intro") { seek(ms: windows.introTo) }
        } else if let ac = windows.afterCredits.first(where: { posMs < $0[0] && $0[0] - posMs < 600_000 }),
                  windows.credits > 0, posMs >= windows.credits {
            SkipPill(text: "After credits ▶") { seek(ms: ac[0]) }
        }
    }

    private func start() async {
        windows = await PlayerWindows.fetch(session: session, id: request.meta.id,
                                            season: request.season, episode: request.episode)
        let item = AVPlayerItem(url: request.url)
        player.replaceCurrentItem(with: item)
        // resume: local positions map first (synced), server pos as fallback
        let key = request.season != nil ? "\(request.meta.id):\(request.season!):\(request.episode!)" : request.meta.id
        let local = ((session.pstate()["positions"] as? [String: Any])?[key] as? String)?
            .split(separator: "|").first.flatMap { Int($0) } ?? 0
        let resume = max(local, windows.resumeMs)
        if resume > 120_000 { seek(ms: resume) }
        player.play()
        // remux fallback for containers AVPlayer can't open
        Task {
            try? await Task.sleep(for: .seconds(4))
            if item.status == .failed { playRemux(fromMs: resume) }
        }
        // position ticker drives skip buttons + subtitle cues + progress saves
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10),
                                       queue: .main) { t in
            posMs = Int(t.seconds * 1000)
            currentCue = subCues.first(where: { posMs >= $0.from && posMs <= $0.to })?.text ?? ""
        }
        await loadSubtitles()
        observeEnd()
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
        let sid = request.season != nil ? "\(request.meta.id):\(request.season!):\(request.episode!)" : request.meta.id
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
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: nil, queue: .main) { _ in
            guard session.pref("autoplayNext", true),
                  let s = request.season, let e = request.episode else { dismiss(); return }
            Task {
                guard let addon = session.addons.first else { dismiss(); return }
                let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let next = "\(request.meta.id):\(s):\(e + 1)"
                if let r = try? await API.json("/stream/series/\(next).json?u=\(u)", base: addon.url),
                   let st = (r["streams"] as? [[String: Any]])?.first,
                   let us = st["url"] as? String, let url = URL(string: us) {
                    nextEpisode = PlayRequest(url: url, meta: request.meta, season: s, episode: e + 1)
                } else { dismiss() }
            }
        }
    }

    private func stop() {
        let pos = Int(player.currentTime().seconds * 1000)
        let durS = player.currentItem?.duration.seconds ?? 0
        let dur = durS.isFinite ? Int(durS * 1000) : 0
        if pos > 5000 {
            let key = request.season != nil ? "\(request.meta.id):\(request.season!):\(request.episode!)" : request.meta.id
            var ps = session.pstate()
            var positions = ps["positions"] as? [String: Any] ?? [:]
            positions[key] = "\(pos)|\(dur)|\(Int(Date().timeIntervalSince1970 * 1000))"
            ps["positions"] = positions
            // Continue Watching entry (stamp-sorted server-side)
            var cw = ps["continue"] as? [[String: Any]] ?? []
            cw.removeAll { $0["id"] as? String == request.meta.id }
            cw.insert(["id": request.meta.id, "type": request.meta.type,
                       "name": request.meta.name, "poster": request.meta.poster ?? ""], at: 0)
            ps["continue"] = Array(cw.prefix(12))
            session.setPstate(ps)
        }
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
