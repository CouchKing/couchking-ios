import SwiftUI

// Series episodes — Android parity: season picker, episode rows with thumbnails
// (blurred when unwatched + pref on), unaired 📅 badge, per-episode progress bars,
// current-episode highlight, per-episode watched eyes, tap thumb = stream sheet,
// tap title = episode detail page.
struct Episode: Identifiable, Hashable {
    let id: String        // "tt123:1:2"
    let season: Int, episode: Int
    let name: String, thumb: String?, released: String?, overview: String?
    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        season = o["season"] as? Int ?? Int(o["season"] as? String ?? "") ?? 0
        episode = o["episode"] as? Int ?? o["number"] as? Int ?? Int(o["episode"] as? String ?? "") ?? 0
        name = o["name"] as? String ?? o["title"] as? String ?? "Episode"
        thumb = o["thumbnail"] as? String
        released = o["released"] as? String
        overview = o["overview"] as? String ?? o["description"] as? String
    }
    var airMs: Int { Session.airMs(released) }
    var unaired: Bool { airMs > Int(Date().timeIntervalSince1970 * 1000) }
    var airDate: String {
        guard airMs > 0 else { return released.map { String($0.prefix(10)) } ?? "" }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: Double(airMs) / 1000))
    }
    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: Episode, b: Episode) -> Bool { a.id == b.id }
}

struct EpisodesView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let videos: [[String: Any]]
    @State private var season = 1
    @State private var pick: Episode?
    @State private var detail: Episode?

    private var all: [Episode] { videos.compactMap(Episode.init) }
    private var episodes: [Episode] {
        all.filter { $0.season == season }.sorted { $0.episode < $1.episode }
    }
    private var seasons: [Int] {
        Array(Set(all.map(\.season))).filter { $0 > 0 }.sorted()
    }
    /// The episode the show resumes at (cwlast) — highlighted as "current".
    private var currentId: String {
        ((session.pstate()["cwlast"] as? [String: Any])?[meta.id] as? String) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(seasons, id: \.self) { s in
                            Button("Season \(s)") { season = s }
                                .buttonStyle(.bordered)
                                .tint(s == season ? Theme.accent : .gray)
                        }
                    }
                }
            }
            ForEach(episodes) { ep in
                EpisodeRow(meta: meta, ep: ep, current: ep.id == currentId,
                           onPlay: { pick = ep }, onDetail: { detail = ep })
            }
        }
        .onAppear {
            // land on the current episode's season, else the first season
            let cur = all.first { $0.id == currentId }
            if let c = cur { season = c.season } else if let f = seasons.first { season = f }
        }
        .sheet(item: $pick) { ep in
            StreamSheet(meta: meta, season: ep.season, episode: ep.episode, episodes: all)
                .ckDetents()
        }
        .sheet(item: $detail) { ep in
            EpisodeDetailView(meta: meta, ep: ep, episodes: all)
                .ckDetents()
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    var current = false
    let onPlay: () -> Void
    let onDetail: () -> Void

    private var watched: Bool {
        ((session.pstate()["watchedIds"] as? [String]) ?? []).contains(ep.id)
    }
    /// Resume fraction from the synced positions map ("pos|dur|ts") — refreshed live by the pull.
    private var progress: Double {
        guard let s = (session.pstate()["positions"] as? [String: Any])?[ep.id] as? String else { return 0 }
        let p = s.split(separator: "|")
        guard p.count >= 2, let pos = Double(p[0]), let dur = Double(p[1]), dur > 0 else { return 0 }
        return min(1, pos / dur)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: ep.thumb ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Theme.card }
                    .frame(width: 128, height: 72)
                    .blur(radius: (!watched && session.pref("blurUnwatched", false)) ? 8 : 0)
                    .clipped()
                    if progress > 0.01 {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3)).frame(width: 128, height: 3)
                            Rectangle().fill(Theme.accent).frame(width: 128 * progress, height: 3)
                        }
                    }
                    if ep.unaired {
                        Text("📅 \(ep.airDate)").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(4)
                    }
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: current ? 2 : 0))
            }.buttonStyle(.plain)
            Button(action: onDetail) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("E\(ep.episode) · \(ep.name)").font(.subheadline).lineLimit(2)
                        .foregroundStyle(current ? Theme.accent : .primary)
                    if !ep.airDate.isEmpty {
                        Text(ep.unaired ? "Airs \(ep.airDate)" : ep.airDate)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button {
                session.toggleEpisodeWatched(ep.id)
            } label: {
                Image(systemName: watched ? "eye.fill" : "eye")
                    .foregroundStyle(watched ? Theme.accent : .secondary)
            }.buttonStyle(.plain)
        }
    }
}

extension Session {
    /// Per-episode watched eye with the scoped `wt:` tombstone (Android epCard eye).
    func toggleEpisodeWatched(_ epId: String) {
        var ps = pstate()
        var ids = ps["watchedIds"] as? [String] ?? []
        let watched = ids.contains(epId)
        var stamps = ps[watched ? "removedTs" : "addedTs"] as? [String: Any] ?? [:]
        if watched { ids.removeAll { $0 == epId } } else { ids.append(epId) }
        stamps["wt:" + epId] = Int(Date().timeIntervalSince1970 * 1000)
        ps["watchedIds"] = ids
        ps[watched ? "removedTs" : "addedTs"] = stamps
        setPstate(ps)
    }
}

// Episode detail page (Android showEpisodeDetail): overview, air date, mark-watched, streams.
struct EpisodeDetailView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    var episodes: [Episode] = []
    @State private var showStreams = false
    private var watched: Bool { session.isWatched(ep.id) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AsyncImage(url: URL(string: ep.thumb ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Theme.card }
                    .frame(height: 190).frame(maxWidth: .infinity).clipped()
                    .blur(radius: (!watched && session.pref("blurUnwatched", false)) ? 10 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(ep.name).font(.title3.bold())
                    Text("\(meta.name) · S\(ep.season) E\(ep.episode)" + (ep.airDate.isEmpty ? "" : " · \(ep.unaired ? "Airs" : "Aired") \(ep.airDate)"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let o = ep.overview, !o.isEmpty {
                        Text(o).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        if session.hasAddon && !ep.unaired {
                            Button { showStreams = true } label: {
                                Label("Play", systemImage: "play.fill").font(.headline)
                                    .padding(.horizontal, 18).padding(.vertical, 10)
                                    .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                            }
                        }
                        Button { session.toggleEpisodeWatched(ep.id) } label: {
                            Label(watched ? "Watched" : "Mark watched", systemImage: watched ? "eye.fill" : "eye")
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.card, in: Capsule())
                                .foregroundStyle(watched ? Theme.accent : .primary)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Episode \(ep.episode)")
            .ckInlineTitle()
            .sheet(isPresented: $showStreams) {
                StreamSheet(meta: meta, season: ep.season, episode: ep.episode, episodes: episodes)
                    .ckDetents()
            }
        }
    }
}

/// Centered CouchKing gate modal (Android showTopBanner / gate card): the reason, one button.
struct GateModal: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("👑").font(.system(size: 40))
            Text(text).font(.subheadline).multilineTextAlignment(.center)
            Button("OK", action: dismiss)
                .font(.headline).padding(.horizontal, 26).padding(.vertical, 10)
                .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
        }
        .padding(26)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
        .padding(30)
    }
}

// Shared stream list for movies + episodes + Live TV channels — CouchKing-styled rows.
// Android Addons.streams parity: ckExpired → expiry banner, ckNotice → notice line, ONE quiet
// 900ms retry so a dropped request never reads "no streams", auto-poll while the warm lands,
// stream gate 429/503/403 → centered modal with the reason (never a spinning player).
// Embeds INLINE on a movie's Details page (Stremio behavior) and in the episode sheet.
struct StreamList: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    var season: Int? = nil
    var episode: Int? = nil
    var episodes: [Episode] = []     // the real episode list (season-crossing next-up)
    var autoplay = false             // Continue Watching resume: play the first stream on arrival
    @State private var streams: [[String: Any]] = []
    @State private var loading = true
    @State private var warming = false
    @State private var expired = false
    @State private var notice = ""
    @State private var gate = ""
    @State private var play: PlayRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // expiry banner WHERE the streams would be — browsing never blocks, only
            // play time shows it (Android expiryBanner parity, AJ Sep 18 rule)
            if session.isExpired || expired {
                VStack(alignment: .center, spacing: 6) {
                    Text("⛔").font(.system(size: 44))
                    Text("Subscription expired").font(.headline)
                    Text("Renew your plan to keep watching.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
            else if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20) }
            else if warming && streams.isEmpty {
                HStack { ProgressView(); Text("Getting this ready… streams appear automatically.") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            else if streams.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No streams right now.").font(.subheadline)
                    Button("Try again") { Task { await load() } }.font(.footnote)
                }
            }
            if !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(streams.prefix(10).enumerated()), id: \.offset) { _, s in
                Button { start(s) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s["name"] as? String ?? "Stream").font(.subheadline.bold())
                        Text(s["title"] as? String ?? s["description"] as? String ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                }
                .ckTile()
            }
        }
        .overlay {
            if !gate.isEmpty {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    GateModal(text: gate) { gate = "" }
                }
            }
        }
        .task { await load() }
        .ckFullScreenCover(item: $play) { req in PlayerView(request: req) }
    }

    /// Stream → PlayRequest (windows riding on the stream object override /player/resume).
    private func start(_ s: [String: Any]) {
        guard let u = s["url"] as? String, let url = URL(string: u) else { return }
        var req = PlayRequest(url: url, meta: meta, season: season, episode: episode)
        req.episodes = episodes
        req.streamWindows = PlayerWindows(stream: s)
        req.subtitles = s["subtitles"] as? [[String: Any]] ?? []
        req.placeholder = PlayRequest.isPlaceholder(s)
        let sid = season != nil ? "\(meta.id):\(season!):\(episode!)" : meta.id
        req.streamPath = "/stream/\(season != nil ? "series" : (meta.type == "tv" ? "tv" : "movie"))/\(sid).json"
        if meta.type == "tv" {
            // Live TV: gate probe first (429/503/403 → reason modal, never a spinning player)
            Task {
                let code = await API.probe(url)
                if let reason = API.gateReason(code) { gate = reason } else { play = req }
            }
        } else { play = req }
    }

    /// Live TV stream pick (Android liveTune): HLS first for everything; the hub `.ts` feed
    /// (`ckTs`) ONLY for the 24/7 loop channels.
    private func pickLive(_ list: [[String: Any]]) -> [[String: Any]] {
        let loop = meta.id.contains("24-7")
        let hls = list.filter { !(($0["ckTs"] as? Bool) ?? false) }
        let ts = list.filter { ($0["ckTs"] as? Bool) ?? false }
        return loop ? (ts + hls) : (hls + ts)
    }

    private func load() async {
        guard !session.isExpired, let base = session.addonBase() else { loading = false; return }
        loading = true; gate = ""
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let sid = season != nil ? "\(meta.id):\(season!):\(episode!)" : meta.id
        // Live TV channels come through as type "tv" with a cklive:<id> — /stream/tv/<id>.json
        let type = season != nil ? "series" : (meta.type == "tv" ? "tv" : "movie")
        // AUTO-POLL when nothing's cached yet (Android "press Play, then again shortly"): the
        // background warm/download lands within a minute — keep re-fetching so the list fills
        // itself instead of dead-ending. Live channels don't warm, so they poll only once.
        let tries = type == "tv" ? 1 : 8
        for attempt in 0..<tries {
            let path = "/stream/\(type)/\(sid).json?u=\(u)"
            var r = try? await API.jsonStatus(path, base: base)
            let empty = (r?.0["streams"] as? [[String: Any]] ?? []).isEmpty
            if r == nil || (r?.1 ?? 0) >= 500 || ((r?.1 ?? 0) == 200 && empty && attempt == 0) {
                // ONE quiet retry (900ms) so a dropped request never reads "no streams"
                try? await Task.sleep(for: .milliseconds(900))
                r = try? await API.jsonStatus(path, base: base)
            }
            if let r {
                let body = r.0, code = r.1
                if let reason = API.gateReason(code) { gate = reason; loading = false; warming = false; return }
                if body["ckExpired"] as? Bool == true { expired = true; loading = false; warming = false; return }
                if let n = body["ckNotice"] as? String { notice = n }
                else if let n = body["ckNotice"] as? Bool, n { notice = "Some streams may take a moment to appear." }
                if let s = body["streams"] as? [[String: Any]], !s.isEmpty {
                    streams = type == "tv" ? pickLive(s) : s
                    loading = false; warming = false
                    if autoplay, let first = streams.first { start(first) }
                    return
                }
            }
            loading = false
            if attempt < tries - 1 { warming = true; try? await Task.sleep(for: .seconds(12)) }
        }
        warming = false
    }
}

/// The stream list as a sheet (episodes, Live TV channels, Continue Watching resume).
struct StreamSheet: View {
    let meta: Meta
    var season: Int? = nil
    var episode: Int? = nil
    var episodes: [Episode] = []
    var autoplay = false
    var body: some View {
        NavigationStack {
            ScrollView {
                StreamList(meta: meta, season: season, episode: episode, episodes: episodes, autoplay: autoplay)
                    .padding(14)
            }
            .background(Theme.bg)
            .navigationTitle(season != nil ? "S\(season!)E\(episode!)" : meta.name)
            .ckInlineTitle()
        }
    }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let meta: Meta
    let season: Int?
    let episode: Int?
    // "Are you still watching?" chain: consecutive fully-input-less auto-advanced
    // episodes so far (rides along because each auto-advance is a fresh PlayerView)
    var idleEps: Int = 0
    var episodes: [Episode] = []             // real episode list → season-crossing next
    var streamWindows: PlayerWindows? = nil  // chapter windows riding on the stream object
    var subtitles: [[String: Any]] = []      // the addon's ranked subtitle files for this stream
    var placeholder = false                  // "not yet available" clip → loop + re-probe + hot-swap
    var streamPath = ""                      // "/stream/<type>/<sid>.json" to re-request the list

    /// IOS_CONTRACTS §5: a stream is still a placeholder when its url is the /unavailable clip
    /// (or _downloading.mp4), its name is the ⏳ progress label, or behaviorHints.notWebReady.
    static func isPlaceholder(_ s: [String: Any]) -> Bool {
        let url = (s["url"] as? String ?? "").lowercased()
        if url.contains("/unavailable") || url.contains("_downloading.mp4") { return true }
        if (s["name"] as? String ?? "").hasPrefix("⏳") { return true }
        return ((s["behaviorHints"] as? [String: Any])?["notWebReady"] as? Bool) ?? false
    }
}
