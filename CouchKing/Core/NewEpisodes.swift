import Foundation

// Continue Watching ordering + "+N new episodes" (Android newEpisodeCount / cwOrder /
// dismissNewEpsBadge, MainActivity ~L3390-3458):
//  - a show floats to the FRONT of CW at the air time of its newest unwatched episode
//    (cwOrder = max(last watch stamp, badge'd air time)), badge "+N"
//  - opening the show dismisses the badge (newEpsSeen[id] = that air time; highest wins
//    across devices in the union merge) — the show then sorts by its watch stamp again.
struct NewEpsInfo {
    var count = 0          // unwatched aired episodes after the last watched one
    var latestAir = 0      // epoch ms of the newest of those
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
        let (ls, le) = lastEpisode(of: meta.id)
        guard ls > 0 else { return NewEpsInfo() }
        let watched = Set(pstate()["watchedIds"] as? [String] ?? [])
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var info = NewEpsInfo()
        for v in videos {
            guard let ep = Episode(v), ep.season > 0 else { continue }
            guard ep.season > ls || (ep.season == ls && ep.episode > le) else { continue }
            let air = Session.airMs(ep.released)
            guard air > 0, air <= now, !watched.contains(ep.id) else { continue }
            info.count += 1
            info.latestAir = max(info.latestAir, air)
        }
        return info
    }

    /// The badge shows until the person opens the show (or another device did).
    func newEpsBadgeVisible(_ id: String, _ info: NewEpsInfo) -> Bool {
        guard info.count > 0 else { return false }
        let seen = StateMerge.stamp((pstate()["newEpsSeen"] as? [String: Any])?[id])
        return info.latestAir > seen
    }

    func dismissNewEpsBadge(_ id: String, latestAir: Int) {
        guard latestAir > 0 else { return }
        var ps = pstate()
        var seen = ps["newEpsSeen"] as? [String: Any] ?? [:]
        if StateMerge.stamp(seen[id]) >= latestAir { return }
        seen[id] = latestAir
        ps["newEpsSeen"] = seen
        setPstate(ps)
    }

    /// The CW row fully ordered (Android cwOrder): newest activity first, a show with a fresh
    /// unwatched episode floats to where that episode's air time lands it.
    func continueWatchingOrdered() async -> [CWItem] {
        var items = continueWatching()
        for i in items.indices where items[i].meta.type == "series" {
            let vids = await MetaCache.shared.videos(for: items[i].meta, session: self)
            let info = newEpisodes(for: items[i].meta, videos: vids)
            if newEpsBadgeVisible(items[i].meta.id, info) {
                items[i].newEps = info.count
                items[i].latestAir = info.latestAir
                items[i].order = max(items[i].order, info.latestAir)
            }
        }
        return items.sorted { $0.order > $1.order }
    }
}
