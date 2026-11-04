import Foundation

// Continue Watching ordering + "+N new episodes" (Android newEpisodeCount / cwOrder /
// dismissNewEpsBadge):
//  - a show floats to the FRONT of CW at the air time of its newest unwatched episode
//    (cwOrder = max(last watch stamp, that air time)), badge "+N"
//  - opening the show dismisses the NUMBER only (newEpsSeen[id] = latest aired key; highest
//    wins across devices in the union merge) — the position boost STAYS until the episodes
//    are actually WATCHED (Android 2.0.251 "peek != reorder": dismissing used to zero the
//    boost too, so the show sank from mid-row to the back the moment you looked at it).
//  - the boost is persisted per title (Android 2.0.256 epboost) so a rebuilt row sorts
//    FINAL on first paint, before the async episode-list pass has run.
struct NewEpsInfo {
    var count = 0          // unwatched aired episodes after the last watched one
    var latestAir = 0      // epoch ms of the newest of those (drives CW ordering)
    var latestKey = 0      // season*10000+episode of the newest AIRED episode — the
                           // dismissal unit every other client uses
}

@MainActor
final class MetaCache {
    static let shared = MetaCache()
    private var videos: [String: [[String: Any]]] = [:]
    private var inflight: Set<String> = []

    /// Episode list for a series (cached for the app's life; the 60s pull re-derives CW
    /// against it, the Details page refreshes it).
    func videos(for meta: Meta, session: Session) async -> [[String: Any]] {
        if let v = videos[meta.id] { return v }
        if inflight.contains(meta.id) { return [] }
        inflight.insert(meta.id)
        let m = await Catalog.fullMeta(session: session, type: meta.type, id: meta.id)
        inflight.remove(meta.id)
        let v = m["videos"] as? [[String: Any]] ?? []
        videos[meta.id] = v
        return v
    }
    func put(_ id: String, videos v: [[String: Any]]) { videos[id] = v }
    func cached(_ id: String) -> [[String: Any]]? { videos[id] }
}

extension Session {
    /// Parse "released" ISO stamps the addon/Cinemeta send ("2024-05-01T00:00:00.000Z").
    nonisolated static func airMs(_ s: String?) -> Int {
        guard let s, s.count >= 10 else { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970 * 1000) }
        let g = DateFormatter(); g.dateFormat = "yyyy-MM-dd"; g.timeZone = TimeZone(identifier: "UTC")
        if let d = g.date(from: String(s.prefix(10))) { return Int(d.timeIntervalSince1970 * 1000) }
        return 0
    }

    /// (season, episode) of the furthest episode this person has watched or resumed.
    func lastEpisode(of id: String) -> (Int, Int) {
        let ps = pstate()
        var best = (0, 0)
        func consider(_ key: String) {
            let p = key.split(separator: ":")
            guard p.count >= 3, p[0] == Substring(id) || key.hasPrefix(id + ":"),
                  let s = Int(p[p.count - 2]), let e = Int(p[p.count - 1]) else { return }
            if s > best.0 || (s == best.0 && e > best.1) { best = (s, e) }
        }
        for k in ps["watchedIds"] as? [String] ?? [] where k.hasPrefix(id + ":") { consider(k) }
        if let last = (ps["cwlast"] as? [String: Any])?[id] as? String { consider(last) }
        return best
    }

    /// Count unwatched, already-aired episodes after the last watched one.
    func newEpisodes(for meta: Meta, videos: [[String: Any]]) -> NewEpsInfo {
        guard meta.type == "series", !videos.isEmpty else { return NewEpsInfo() }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let watched = Set(pstate()["watchedIds"] as? [String] ?? [])
        // aired episodes only, in order — the whole count is derived against these
        let aired = videos.compactMap { Episode($0) }
            .filter { $0.season > 0 && { let a = Session.airMs($0.released); return a > 0 && a <= now }($0) }
            .sorted { $0.season != $1.season ? $0.season < $1.season : $0.episode < $1.episode }
        guard !aired.isEmpty else { return NewEpsInfo() }
        let (ls, le) = lastEpisode(of: meta.id)

        // NEVER-WATCHED library show (Android: "even if I haven't watched them") — badge the
        // episodes that aired AFTER the show was added. No add-stamp → the whole back
        // catalogue is not "new", so no badge. Capped at 9, exactly like Android/web/desktop.
        if ls == 0 {
            let addedAt = StateMerge.stamp((pstate()["addedTs"] as? [String: Any])?["wl:" + meta.id])
            guard addedAt > 0 else { return NewEpsInfo() }
            let fresh = aired.filter { Session.airMs($0.released) > addedAt && !watched.contains($0.id) }
            var info = NewEpsInfo()
            info.count = min(9, fresh.count)
            info.latestAir = fresh.map { Session.airMs($0.released) }.max() ?? 0
            info.latestKey = aired.map { $0.season * 10000 + $0.episode }.max() ?? 0
            return info
        }

        // BINGEING OLD SEASONS: don't flash the whole "+9" backlog — but a genuinely-new drop
        // (aired in the last ~2 weeks) SHOULD still pop a +1 and move the show to front even
        // many seasons behind (AJ Oct 23, Grey's at S12 while S23 airs). Far behind = count
        // only recently-aired fresh eps; caught-up = unchanged.
        let maxSeason = aired.map { $0.season }.max() ?? 0
        let freshAll = aired.filter {
            ($0.season > ls || ($0.season == ls && $0.episode > le)) && !watched.contains($0.id)
        }
        let recentCut = Int(Date().timeIntervalSince1970 * 1000) - 14 * 86_400_000
        let fresh = ls < maxSeason - 1
            ? freshAll.filter { Session.airMs($0.released) > recentCut }
            : freshAll
        var info = NewEpsInfo()
        info.count = min(9, fresh.count)
        info.latestAir = fresh.map { Session.airMs($0.released) }.max() ?? 0
        info.latestKey = aired.map { $0.season * 10000 + $0.episode }.max() ?? 0
        return info
    }

    /// The badge shows until the person opens the show (or another device did).
    /// UNIT FIX (AJ Sep 30, Speed Buggy "+9 on a 1970s show"): Android/web/desktop store
    /// newEpsSeen as season*10000+episode — iOS wrote epoch MILLISECONDS and compared
    /// epoch > key, so a dismissal made on any other device NEVER hid the badge here.
    func newEpsBadgeVisible(_ id: String, _ info: NewEpsInfo) -> Bool {
        guard info.count > 0 else { return false }
        let seen = StateMerge.stamp((pstate()["newEpsSeen"] as? [String: Any])?[id])
        return info.latestKey > seen
    }

    func dismissNewEpsBadge(_ id: String, latestKey: Int) {
        guard latestKey > 0 else { return }
        var ps = pstate()
        var seen = ps["newEpsSeen"] as? [String: Any] ?? [:]
        if StateMerge.stamp(seen[id]) >= latestKey { return }
        seen[id] = latestKey
        ps["newEpsSeen"] = seen
        setPstate(ps)
    }

    // Per-title new-episode ORDER boost (air time of the newest unwatched drop), persisted
    // like Android's Store.epBoost — so CW sorts the same at cold build and after the async
    // recompute (the row must never visibly re-sort after first paint).
    private var epBoostKey: String { "epboost." + currentProfile }
    func epBoosts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: epBoostKey) as? [String: Int]) ?? [:]
    }
    func setEpBoost(_ id: String, _ v: Int) {
        var m = epBoosts()
        if (v > 0 ? m[id] == v : m[id] == nil) { return }   // no-op writes skipped
        if v > 0 { m[id] = v } else { m.removeValue(forKey: id) }
        UserDefaults.standard.set(m, forKey: epBoostKey)
    }

    /// The CW row in its FINAL order, synchronously (Android 2.0.256 first-paint fix): the
    /// persisted boosts answer before any episode list has loaded. The async pass below only
    /// adds the +N badges (and any boost the persisted map missed).
    func continueWatchingSeeded() -> [CWItem] {
        var items = continueWatching()
        let boosts = epBoosts()
        for i in items.indices where items[i].meta.type == "series" {
            items[i].order = max(items[i].order, boosts[items[i].meta.id] ?? 0)
        }
        return items.sorted { $0.order > $1.order }
    }

    /// The CW row fully ordered (Android cwOrder): newest activity first, a show with a fresh
    /// unwatched episode floats to where that episode's air time lands it — WHETHER OR NOT
    /// the +N badge was dismissed (the boost only decays once the episodes are watched:
    /// latestAir derives from unwatched eps, so watching them zeroes it naturally).
    func continueWatchingOrdered() async -> [CWItem] {
        var items = continueWatching()
        let boosts = epBoosts()
        for i in items.indices where items[i].meta.type == "series" {
            let id = items[i].meta.id
            let vids = await MetaCache.shared.videos(for: items[i].meta, session: self)
            // in-flight / failed fetch → the persisted boost holds the order steady
            guard !vids.isEmpty else {
                items[i].order = max(items[i].order, boosts[id] ?? 0)
                continue
            }
            let info = newEpisodes(for: items[i].meta, videos: vids)
            items[i].latestAir = info.latestAir
            items[i].latestKey = info.latestKey
            items[i].order = max(items[i].order, info.latestAir)
            if newEpsBadgeVisible(id, info) { items[i].newEps = info.count }
            setEpBoost(id, info.latestAir)
        }
        return items.sorted { $0.order > $1.order }
    }
}
