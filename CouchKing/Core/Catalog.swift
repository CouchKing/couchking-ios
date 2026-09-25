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
}

struct Catalog {
    /// Rows shown on Home, in Android's order. For You + Trending etc. come from the
    /// user's addon; guests get TMDB-powered discovery rows instead (tracker mode).
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
}
