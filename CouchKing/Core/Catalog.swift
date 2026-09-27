import Foundation

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
            rows = tmp.sorted { $0.0 < $1.0 }.filter { !$0.2.isEmpty }.map { ($0.1, $0.2) }
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
