import Foundation

#if os(iOS)

// OFFLINE DOWNLOADS — iPhone mirror of the Android full-flavor Downloads object (Downloads.kt):
// save a movie/episode onto the phone and play it with zero internet. iPhone only, exactly like
// Android (mobile only — the Firestick / Apple TV / Mac never show any of it), so the whole file
// is `#if os(iOS)` and every call site is guarded the same way.
//
// Pipeline (Android parity): the ⬇ button resolves streams EXACTLY like the play path, asks the
// server's /dlpick for the smallest healthy ≤1080p H264 copy (REAL byte counts + matched English
// subs — the client stream list is quality-ranked top-3, which is how phones landed 8GB copies),
// confirms with the size, then saves the small extras FIRST while we're certainly online
// (subtitles + learned intro/credits windows — exactly the things offline playback can't fetch
// later) and hands the media itself to a BACKGROUND URLSession so the transfer survives the app
// being backgrounded or killed.
//
// Storage: Application Support/Downloads/<imdbId>/<key>.<ext> (+ up to 3 .srt files), excluded
// from iCloud backup, plus ONE index.json with every item's metadata — offline playback needs
// NOTHING from the network, not even the skip-intro timings. Items are PER ACCOUNT+PROFILE on
// the device (Android Sep 14): each profile only sees, plays, and deletes its own.
final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    /// Flavor flag kept for Android parity (the store flavors there compile this to false).
    static let ENABLED = true
    /// Headroom the phone always keeps (Android FLOOR): refuse a download that would leave
    /// less than this free — a phone filled to the brim breaks everything else on it.
    static let floorBytes: Int64 = 500 * 1024 * 1024

    /// One downloaded (or in-flight) item, straight from index.json (Android's per-item meta).
    struct Item: Identifiable, Codable, Equatable {
        var key: String          // sanitize(profile)_sanitize(itemId): identity + filename stem
        var itemId: String       // "tt123" (movie) / "tt123:1:2" (episode)
        var profile: String      // "email|profileId" — items()/state() only surface matches
        var type: String         // movie | series
        var showName: String
        var epName: String
        var season: Int
        var episode: Int
        var poster: String
        var url: String          // the resolved /tbplay url (kept for retry — may expire, see TODO)
        var quality: String      // "1080p" / "720p" / "" when unknown
        var sizeBytes: Int64
        var introFrom: Int       // learned windows captured AT DOWNLOAD TIME (ms) — they replace
        var introTo: Int         // the /player/resume fetch the player skips for offline plays
        var recapFrom: Int
        var recapTo: Int
        var credits: Int
        var subFiles: [String]   // .srt paths relative to the Downloads dir
        var state: String        // queued | downloading | done | failed
        var ts: Int
        var file: String         // media path relative to the Downloads dir ("tt123/<key>.mp4")
        var note: String?        // failure reason for the row ("not enough free space" etc.)
        var id: String { key }
        var isMKV: Bool { file.lowercased().hasSuffix(".mkv") }
        var label: String { type == "series" ? "\(showName) S\(season)E\(episode)" : showName }
    }

    /// What the confirm dialog offers (Android DlPick/DlOpt): one lean pick + its subtitles.
    struct Offer {
        let itemId: String, type: String, showName: String, epName: String
        let season: Int, episode: Int
        let poster: String
        let url: String
        let bytes: Int64         // real byte count from /dlpick; -1 = unknown (fallback path)
        let quality: String
        let subs: [[String: Any]]
        /// "1080p — 2.3 GB" / "2.3 GB" / "Size unknown" — the one line under "Download X?".
        var line: String {
            let q = quality.isEmpty ? "" : quality + " — "
            if bytes <= 0 { return quality.isEmpty ? "Size unknown" : quality }
            if bytes >= 5_000_000_000 { return "\(q)\(Downloads.gb(bytes)) GB (big file)" }
            return "\(q)\(Downloads.gb(bytes)) GB"
        }
    }

    struct Progress { var got: Int64; var total: Int64 }   // total -1 = unknown

    @Published private(set) var items: [Item] = []
    /// Live transfer counters keyed by item key — fed by the delegate, read by the tab's bars.
    @Published private(set) var progress: [String: Progress] = [:]

    /// handleEventsForBackgroundURLSession's completion — called once the event drain finishes.
    var backgroundCompletion: (() -> Void)?

    private var tasks: [String: URLSessionDownloadTask] = [:]   // main-thread only
    private var resumeData: [String: Data] = [:]                // cheap resume after a drop
    private var lastPub: [String: Int64] = [:]                  // progress publish throttle
    private let dirURL: URL
    private var indexURL: URL { dirURL.appendingPathComponent("index.json") }

    /// The one background session — downloads keep running while the app is backgrounded or
    /// killed; iOS relaunches us into handleEventsForBackgroundURLSession to finish up.
    private lazy var bg: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "app.couchking.ios.downloads")
        cfg.isDiscretionary = false            // the user explicitly asked — start now
        cfg.sessionSendsLaunchEvents = true    // relaunch the app when a transfer finishes
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        // Application Support/Downloads, created up front and EXCLUDED FROM BACKUP — big media
        // files must never ride into the user's iCloud quota (App Store guideline 2.23).
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? d.setResourceValues(rv)
        dirURL = d
        super.init()
        items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: indexURL))) ?? []
        wake()
        reattach()
    }

    /// Touch the lazy session so a relaunch re-creates it (its tasks re-attach to the delegate).
    func wake() { _ = bg }

    // ---------------- identity / storage layout ----------------

    /// Downloads are PER ACCOUNT+PROFILE on the device (Android profileKey): "guest|" when
    /// signed out; email lowercased so a re-sign-in with different casing can't strand a library.
    @MainActor private func profileKey(_ s: Session) -> String {
        let e = s.email.trimmingCharacters(in: .whitespaces).lowercased()
        return (e.isEmpty ? "guest" : e) + "|" + s.currentProfile
    }
    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }
    private func safeKey(_ pk: String, _ id: String) -> String { sanitize(pk) + "_" + sanitize(id) }
    private func baseId(_ itemId: String) -> String { String(itemId.split(separator: ":").first ?? Substring(itemId)) }

    func mediaURL(_ it: Item) -> URL { dirURL.appendingPathComponent(it.file) }

    // ---------------- queries (drive the ⬇ glyphs + the tab) ----------------

    /// ""=not downloaded, "queued", "downloading", "done", "failed" — scoped to the ACTIVE
    /// profile: another profile's copy of the same id reads as "".
    @MainActor func state(_ itemId: String, session s: Session) -> String {
        items.first(where: { $0.key == safeKey(profileKey(s), itemId) })?.state ?? ""
    }

    /// The active profile's items, newest first.
    @MainActor func items(for s: Session) -> [Item] {
        let pk = profileKey(s)
        return items.filter { $0.profile == pk }.sorted { $0.ts > $1.ts }
    }

    // ---------------- entitlement gate (server /dl/<subKey>/allowed.json) ----------------

    /// The server's verdict on whether THIS key may download (AJ Nov 27 "download button only
    /// if that person is whitelisted", same pattern as the Live TV gate): FALSE until the
    /// server has ever said yes — an unknown or expired key never sees the feature at all.
    /// The last confirmed verdict persists across launches (airplane-mode playback is the
    /// whole point of downloads, so a relaunch with no signal must not hide the library);
    /// only a CONFIRMED {"dl":false} flips it off — and that PURGES everything saved (an
    /// expired member keeps nothing). Network misses / non-200s keep the last word.
    @Published private(set) var allowed = UserDefaults.standard.bool(forKey: "downloadsAllowed")
    private var allowedAskTs: TimeInterval = 0

    /// Launch + every foreground (CouchKingApp), self-throttled to one ask per 10 minutes.
    @MainActor func refreshAllowed(session s: Session) {
        let key = s.subKey
        guard !key.isEmpty, let base = gateBase(s) else { return }   // no addon yet — retry next call
        let now = Date().timeIntervalSince1970
        guard now - allowedAskTs >= 600 else { return }
        allowedAskTs = now
        Task {
            guard let r = try? await API.jsonStatus("/dl/\(key)/allowed.json", base: base, fresh: true),
                  r.1 == 200, let ok = r.0["dl"] as? Bool else { return }
            self.setAllowed(ok)
        }
    }

    /// scheme://host off the installed addon url — the SAME host /dlpick answers on (the
    /// addon and the download gate live together; no baked domain, like firstTbplay).
    @MainActor private func gateBase(_ s: Session) -> String? {
        guard let a = s.addons.first, var c = URLComponents(string: a.url), c.host != nil else { return nil }
        c.path = ""; c.query = nil; c.fragment = nil
        return c.string
    }

    @MainActor private func setAllowed(_ ok: Bool) {
        UserDefaults.standard.set(ok, forKey: "downloadsAllowed")
        if allowed != ok { allowed = ok }
        guard !ok else { return }
        // the server said no (expired / revoked / off the whitelist): an expired member keeps
        // NOTHING — stop every transfer, then clear the Downloads dir (files + index.json)
        for it in items { delete(it) }   // iterates a value copy; delete() mutates self.items
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? [] {
            try? FileManager.default.removeItem(at: dirURL.appendingPathComponent(n))
        }
    }

    // ---------------- resolve (the ⬇ tap) ----------------

    /// Resolve EXACTLY like the play path, then lean-pick: ask the addon for this item's
    /// streams, pull base+subKey off a /tbplay url, and ask the server's /dlpick for the
    /// smallest healthy ≤1080p H264 copy (real bytes + matched English subs). Any miss →
    /// first playable stream with its own subtitle list (size unknown) — the preference must
    /// never cost a download. Nil only when nothing playable exists at all.
    @MainActor
    func resolveOffer(session s: Session, meta: Meta, season: Int?, episode: Int?, epName: String?) async -> Offer? {
        guard let base = s.addonBase() else { return nil }
        let u = s.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let isEp = season != nil && episode != nil
        let sid = isEp ? "\(meta.id):\(season!):\(episode!)" : meta.id
        let type = isEp ? "series" : "movie"
        let r = try? await API.json("/stream/\(type)/\(sid).json?u=\(u)", base: base)
        let streams = (r?["streams"] as? [[String: Any]] ?? []).filter {
            ($0["ckBlocked"] as? Bool) != true && !PlayRequest.isPlaceholder($0)
        }
        func make(url: String, bytes: Int64, q: String, subs: [[String: Any]]) -> Offer {
            Offer(itemId: sid, type: type, showName: meta.name, epName: epName ?? "",
                  season: season ?? 0, episode: episode ?? 0, poster: meta.poster ?? "",
                  url: url, bytes: bytes, quality: q, subs: subs)
        }
        // FIRST CHOICE: the server's /dlpick (Android dlpickOptions) — base + subKey come off
        // a resolved stream url, so this works whatever service the account points at.
        if let m = firstTbplay(streams) {
            let imdb = baseId(meta.id)
            let se = isEp ? "&s=\(season!)&e=\(episode!)" : "&s=&e="
            let t = meta.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let d = try? await API.json("/dlpick/\(m.subKey)?i=\(imdb)\(se)&t=\(t)&u=download", base: m.base),
               let opts = d["options"] as? [[String: Any]], !opts.isEmpty {
                // options arrive best-first — [0] is the quality-floor 1080p lean pick
                let best = opts.first(where: { Self.num($0["bytes"]) > 0 }) ?? opts[0]
                if let us = best["url"] as? String, !us.isEmpty {
                    return make(url: us, bytes: Self.num(best["bytes"]),
                                q: best["q"] as? String ?? "",
                                subs: d["subtitles"] as? [[String: Any]] ?? [])
                }
            }
        }
        // fallback: the first playable stream, its own subtitle list riding along
        guard let st = streams.first, let us = st["url"] as? String, URL(string: us) != nil else { return nil }
        return make(url: us, bytes: -1, q: "", subs: st["subtitles"] as? [[String: Any]] ?? [])
    }

    /// base + subKey off the first service stream url (Android svcUrlRe — no baked domain).
    private func firstTbplay(_ streams: [[String: Any]]) -> (base: String, subKey: String)? {
        guard let re = try? NSRegularExpression(pattern: "(https?://[^/]+)/(?:a/)?tbplay/([^/?]+)/") else { return nil }
        for s in streams {
            guard let us = s["url"] as? String else { continue }
            if let m = re.firstMatch(in: us, range: NSRange(us.startIndex..., in: us)),
               let b = Range(m.range(at: 1), in: us), let k = Range(m.range(at: 2), in: us) {
                return (String(us[b]), String(us[k]))
            }
        }
        return nil
    }

    /// bytes arrives as number OR string depending on the resolver row — take both (Android).
    private static func num(_ v: Any?) -> Int64 {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? Double { return Int64(n) }
        if let s = v as? String, let d = Double(s) { return Int64(d) }
        return 0
    }

    // ---------------- enqueue / delete ----------------

    /// The confirm dialog said Download: index the item NOW (the tab lists it the moment you
    /// tap), then capture extras + start the background transfer.
    @MainActor func enqueue(_ o: Offer, session s: Session) {
        guard allowed else { return }   // gate closed between confirm and tap — never save
        let pk = profileKey(s)
        let key = safeKey(pk, o.itemId)
        if let cur = items.first(where: { $0.key == key }),
           cur.state == "queued" || cur.state == "downloading" { return }   // already on it
        // re-download over a failed/old copy: clean slate first
        if let old = items.first(where: { $0.key == key }) { wipeFiles(old) }
        items.removeAll { $0.key == key }
        items.append(Item(key: key, itemId: o.itemId, profile: pk, type: o.type,
                          showName: o.showName, epName: o.epName, season: o.season,
                          episode: o.episode, poster: o.poster, url: o.url, quality: o.quality,
                          sizeBytes: max(o.bytes, 0), introFrom: 0, introTo: 0, recapFrom: 0,
                          recapTo: 0, credits: 0, subFiles: [],
                          state: "queued", ts: nowMs(), file: "", note: nil))
        persist()
        Task { await self.prepareAndStart(key: key, offer: o, session: s) }
    }

    /// The per-item pipeline. Order matters (Android download()): the SMALL extras — subtitles
    /// and the learned intro/credits windows — are captured FIRST while we're certainly online;
    /// they're exactly the things offline playback can't fetch later. Then the media rides the
    /// background session.
    @MainActor private func prepareAndStart(key: String, offer o: Offer, session s: Session) async {
        // free-space guard UP FRONT: always leave 500MB of headroom or refuse loudly
        if o.bytes > 0, freeBytes() < o.bytes + Self.floorBytes {
            fail(key, "not enough free space (needs \(Self.gb(o.bytes + Self.floorBytes)) GB free)")
            return
        }
        let imdb = baseId(o.itemId)
        let itemDir = dirURL.appendingPathComponent(imdb, isDirectory: true)
        try? FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        // -- up to 3 English .srt files (server-matched list from /dlpick, or the stream's own) --
        var subRel: [String] = []
        for (i, sub) in englishSubs(o.subs).prefix(3).enumerated() {
            guard let su = sub["url"] as? String, let u = URL(string: su) else { continue }
            var rq = URLRequest(url: u); rq.timeoutInterval = 15
            guard let (d, resp) = try? await URLSession.shared.data(for: rq),
                  ((resp as? HTTPURLResponse)?.statusCode ?? 200) == 200, !d.isEmpty else { continue }
            let rel = "\(imdb)/\(key).sub\(i).srt"
            if (try? d.write(to: dirURL.appendingPathComponent(rel), options: .atomic)) != nil {
                subRel.append(rel)
            }
        }

        // -- learned intro/credits windows: one /player/resume call, stored into the index so
        //    Skip Intro and the Next-Up timing work in airplane mode. Zero/absent on any miss —
        //    playback degrades politely --
        let w = await PlayerWindows.fetch(session: s, id: imdb,
                                          season: o.type == "series" ? o.season : nil,
                                          episode: o.type == "series" ? o.episode : nil)

        // -- real container off the redirect chain's FINAL url (/tbplay 302s to the proxied
        //    file, whose path carries the name): AVPlayer cares about the extension at play
        //    time, and the tab warns on MKV (AVFoundation can't open Matroska locally) --
        var ext = "mp4"
        if let u = URL(string: o.url), let chain = await API.redirectChain(u),
           let last = chain.last, let lu = URL(string: last) {
            let e = lu.pathExtension.lowercased()
            if ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts"].contains(e) { ext = e }
        }
        let rel = "\(imdb)/\(key).\(ext)"

        guard let u = URL(string: o.url) else { fail(key, "bad stream url"); return }
        guard let i = items.firstIndex(where: { $0.key == key }) else { return }   // deleted meanwhile
        items[i].subFiles = subRel
        items[i].introFrom = w.introFrom; items[i].introTo = w.introTo
        items[i].recapFrom = w.recapFrom; items[i].recapTo = w.recapTo
        items[i].credits = w.credits
        items[i].file = rel
        items[i].state = "downloading"
        persist()

        let task = bg.downloadTask(with: URLRequest(url: u))
        task.taskDescription = key + "|" + rel   // key never contains "|" (sanitized) — the
                                                 // delegate derives everything from this alone
        tasks[key] = task
        task.resume()
    }

    /// Delete (or stop-and-delete while in flight): instant space back, meta gone.
    @MainActor func delete(_ it: Item) {
        tasks[it.key]?.cancel()   // didCompleteWithError sees .cancelled and stands down
        tasks[it.key] = nil
        progress[it.key] = nil
        resumeData[it.key] = nil
        wipeFiles(it)
        items.removeAll { $0.key == it.key }
        persist()
    }

    /// Failed item → try again: resume data when the drop left some (cheap), else a fresh
    /// request on the stored url. NOTE: the stored /tbplay url re-resolves per request on the
    /// server, so a retry hours later still works while the subscription does.
    @MainActor func retry(_ it: Item) {
        guard it.state == "failed", let i = items.firstIndex(where: { $0.key == it.key }) else { return }
        let task: URLSessionDownloadTask
        if let rd = resumeData[it.key] {
            task = bg.downloadTask(withResumeData: rd)
            resumeData[it.key] = nil
        } else if let u = URL(string: it.url), !it.file.isEmpty {
            task = bg.downloadTask(with: URLRequest(url: u))
        } else { return }
        task.taskDescription = it.key + "|" + it.file
        items[i].state = "downloading"; items[i].note = nil
        persist()
        tasks[it.key] = task
        task.resume()
    }

    /// PlayerView's exit path calls this when an OFFLINE-played item crossed the watched
    /// threshold — honoring the tab's "Auto-delete watched" toggle (Android watchedOffline).
    @MainActor func watchedOffline(itemId: String) {
        guard UserDefaults.standard.bool(forKey: "dlAutoDeleteWatched") else { return }
        let key = safeKey(profileKey(Session.shared), itemId)
        guard let it = items.first(where: { $0.key == key }), it.state == "done" else { return }
        delete(it)
    }

    private func wipeFiles(_ it: Item) {
        let itemDir = dirURL.appendingPathComponent(baseId(it.itemId), isDirectory: true)
        // the "." makes this exact-item: media + .subN.srt — never the show's other episodes
        let names = (try? FileManager.default.contentsOfDirectory(atPath: itemDir.path)) ?? []
        for n in names where n.hasPrefix(it.key + ".") {
            try? FileManager.default.removeItem(at: itemDir.appendingPathComponent(n))
        }
        if ((try? FileManager.default.contentsOfDirectory(atPath: itemDir.path)) ?? []).isEmpty {
            try? FileManager.default.removeItem(at: itemDir)
        }
    }

    // ---------------- offline play ----------------

    /// The normal PlayerView, pointed at the LOCAL file. Everything the online path fetches
    /// (intro/credits windows, subtitles) rides in on the request, and offline=true tells the
    /// player to skip its network lanes entirely. Continue Watching parity: positions are plain
    /// pstate keys, so they sync out whenever the phone is back on the internet (Android play()).
    @MainActor func playRequest(_ it: Item) -> PlayRequest? {
        let media = mediaURL(it)
        guard it.state == "done", FileManager.default.fileExists(atPath: media.path) else { return nil }
        let meta = Meta(id: baseId(it.itemId), type: it.type, name: it.showName,
                        poster: it.poster.isEmpty ? nil : it.poster)
        var req = PlayRequest(url: media, meta: meta,
                              season: it.type == "series" ? it.season : nil,
                              episode: it.type == "series" ? it.episode : nil)
        req.offline = true
        var w = PlayerWindows()
        w.introFrom = it.introFrom; w.introTo = it.introTo
        w.recapFrom = it.recapFrom; w.recapTo = it.recapTo
        w.credits = it.credits
        req.streamWindows = w
        req.subtitles = it.subFiles.enumerated().compactMap { i, rel -> [String: Any]? in
            let f = dirURL.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            return ["url": f.absoluteString, "lang": "English (downloaded \(i + 1))"]
        }
        return req
    }

    // ---------------- background session delegate ----------------

    private func key(of task: URLSessionTask) -> String? {
        task.taskDescription?.split(separator: "|").first.map(String.init)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = key(of: downloadTask) else { return }
        DispatchQueue.main.async {
            // throttle: publish every ~2MB (plus the first callback) — not every chunk
            if totalBytesWritten - (self.lastPub[key] ?? -2_000_000) < 2_000_000 { return }
            self.lastPub[key] = totalBytesWritten
            self.progress[key] = Progress(got: totalBytesWritten,
                                          total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // the temp file dies when this returns — move it BEFORE hopping threads
        guard let td = downloadTask.taskDescription else { return }
        let parts = td.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (key, rel) = (parts[0], parts[1])
        let dest = dirURL.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        var size: Int64 = 0
        var moved = false
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            moved = true
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        } catch {}
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        DispatchQueue.main.async {
            self.tasks[key] = nil
            self.progress[key] = nil
            self.lastPub[key] = nil
            guard let i = self.items.firstIndex(where: { $0.key == key }) else {
                try? FileManager.default.removeItem(at: dest)   // deleted mid-flight
                return
            }
            // a 4xx/5xx body "downloads" fine — a tiny non-2xx file is a failure, not a movie
            if moved && (200..<300).contains(code) && size > 0 {
                self.items[i].state = "done"
                self.items[i].sizeBytes = size
                self.items[i].ts = self.nowMs()
                self.items[i].note = nil
            } else {
                try? FileManager.default.removeItem(at: dest)
                self.items[i].state = "failed"
                self.items[i].note = moved ? "server said \(code)" : "couldn't save the file"
            }
            self.persist()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = key(of: task) else { return }   // success handled above
        let ns = error as NSError
        let cancelled = ns.code == NSURLErrorCancelled
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async {
            self.tasks[key] = nil
            self.progress[key] = nil
            self.lastPub[key] = nil
            if cancelled { return }   // user delete — delete() already wiped everything
            self.resumeData[key] = resume   // retry picks up where the connection dropped
            if let i = self.items.firstIndex(where: { $0.key == key }) {
                self.items[i].state = "failed"
                self.items[i].note = "network dropped"
                self.persist()
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }

    /// A relaunch restored the background session's tasks — re-own them, and surface items the
    /// index says are in-flight but nobody owns as failed (Android liveState: the app died
    /// mid-transfer) so the row offers Retry/Delete instead of a forever-stuck bar.
    private func reattach() {
        bg.getAllTasks { ts in
            DispatchQueue.main.async {
                for t in ts {
                    guard let k = self.key(of: t), let dt = t as? URLSessionDownloadTask else { continue }
                    self.tasks[k] = dt
                }
                var changed = false
                for i in self.items.indices
                where (self.items[i].state == "queued" || self.items[i].state == "downloading")
                      && self.tasks[self.items[i].key] == nil {
                    self.items[i].state = "failed"
                    self.items[i].note = "interrupted"
                    changed = true
                }
                if changed { self.persist() }
            }
        }
    }

    // ---------------- small helpers ----------------

    private func fail(_ key: String, _ why: String) {
        DispatchQueue.main.async {
            if let i = self.items.firstIndex(where: { $0.key == key }) {
                self.items[i].state = "failed"
                self.items[i].note = why
                self.persist()
            }
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(items) { try? d.write(to: indexURL, options: .atomic) }
    }

    private func englishSubs(_ subs: [[String: Any]]) -> [[String: Any]] {
        subs.filter { s in
            guard let u = s["url"] as? String, !u.isEmpty else { return false }
            let lang = (s["lang"] as? String ?? "").lowercased()
            let name = (s["name"] as? String ?? "").lowercased()
            return lang.isEmpty || lang.hasPrefix("en") || name.contains("english")
        }
    }

    private func freeBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    static func gb(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1e9) }
}

#endif
