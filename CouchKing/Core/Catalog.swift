import Foundation

// Deterministic seeded RNG so a category row's order is stable ALL DAY for a given profile but
// differs per person and per day (Android profileMix parity).
struct SeededGen: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}
private func fnv(_ str: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in str.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

// Addon catalog fetches — the same rows as Android's Home, in the same order.
struct Meta: Identifiable, Hashable {
    let id: String, type: String, name: String, poster: String?
    init?(_ o: [String: Any], type fallback: String) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        type = o["type"] as? String ?? fallback
        name = o["name"] as? String ?? ""
        poster = o["poster"] as? String
    }
    /// Round-trips into the synced state blobs (watchlist/continue/watched entries).
    var dict: [String: Any] { ["id": id, "type": type, "name": name, "poster": poster ?? ""] }
}

struct Catalog {
    /// Rows shown on Home, in Android's order. For You + Trending etc. come from the
    /// user's addon; guests get TMDB-powered discovery rows instead (tracker mode).
    @MainActor
    static func homeRows(session: Session) async -> [(String, [Meta])] {
        var rows: [(String, [Meta])] = []
        guard let addon = session.addons.first else { return rows }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let wanted: [(String, String, String)] = [
            ("For You — Movies", "movie", "couchking-foryou-movies"),
            ("For You — Shows", "series", "couchking-foryou-series"),
            ("Trending Movies", "movie", "couchking-movies"),
            ("Trending Shows", "series", "couchking-series"),
            ("🍅 Certified Fresh", "movie", "ck-fresh"),
            ("⭐ Top Rated", "series", "ck-top"),
            ("🎬 New in Theaters", "movie", "ck-new"),
        ]
        await withTaskGroup(of: (Int, String, [Meta]).self) { group in
            for (i, (title, type, id)) in wanted.enumerated() {
                group.addTask {
                    let path = "/catalog/\(type)/\(id).json?u=\(u)"
                    let r = (try? await API.json(path, base: addon.url)) ?? [:]
                    let metas = (r["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: type) }
                    return (i, title, metas)
                }
            }
            var tmp: [(Int, String, [Meta])] = []
            for await x in group { tmp.append(x) }
            // per-profile, per-day shuffle of each category row (Android profileMix): stable all day,
            // fresh tomorrow, and different per person. "For You" rows keep their ranked order.
            let day = Int(Date().timeIntervalSince1970 / 86400)
            let who = session.currentProfile.isEmpty ? "guest" : session.currentProfile
            rows = tmp.sorted { $0.0 < $1.0 }.filter { !$0.2.isEmpty }.map { row in
                if row.1.contains("For You") { return (row.1, row.2) }
                var gen = SeededGen(fnv("\(who)|\(day)|\(row.1)"))
                return (row.1, row.2.shuffled(using: &gen))
            }
        }
        return rows
    }

    /// Top 10 Today (Android addTop10Row): trending movies + shows interleaved, first 10.
    @MainActor
    static func top10(session: Session) async -> [Meta] {
        guard let addon = session.addons.first else { return [] }
        async let m = API.json("/catalog/movie/couchking-movies.json", base: addon.url)
        async let s = API.json("/catalog/series/couchking-series.json", base: addon.url)
        let mv = ((try? await m)?["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
        let sv = ((try? await s)?["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "series") }
        var out: [Meta] = []
        var i = 0
        while out.count < 10 && (i < mv.count || i < sv.count) {
            if i < mv.count { out.append(mv[i]) }
            if out.count < 10 && i < sv.count { out.append(sv[i]) }
            i += 1
        }
        return Array(out.prefix(10))
    }
}
