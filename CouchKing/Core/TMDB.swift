import Foundation

// TMDB discovery layer (the port of Android's Discovery.kt, per IOS_CONTRACTS.md §1).
// Clients call TMDB v3 directly with the same public read-only key Android ships. Everything
// keys off IMDb ids: TMDB results resolve to `tt…` via /external_ids before they become Metas.
// "This product uses the TMDB API but is not endorsed or certified by TMDB."
enum TMDB {
    static let key = "b05e998c589bf1393c1059bd1d4c5895"
    static let base = "https://api.themoviedb.org/3"
    static func img(_ path: String?, _ size: String = "w342") -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/\(size)\(p)"
    }

    /// GET a TMDB path (query string without api_key). Nil on any failure. Answers are kept for
    /// 10 minutes in memory (Android Http.jsonCached) so Home repaints and row re-fills don't
    /// re-download the same pages.
    static func get(_ path: String, _ query: String = "") async -> [String: Any]? {
        let sep = query.isEmpty ? "" : "&"
        let raw = "\(base)\(path)?api_key=\(key)\(sep)\(query)"
        if let hit = cached(raw) { return hit }
        guard let url = URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        guard let res = try? await URLSession.shared.data(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any] else { return nil }
        remember(raw, j)
        return j
    }

    private static let cacheLock = NSLock()
    private static var memo: [String: (Date, [String: Any])] = [:]
    private static func cached(_ k: String) -> [String: Any]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let e = memo[k], Date().timeIntervalSince(e.0) < 600 else { return nil }
        return e.1
    }
    private static func remember(_ k: String, _ v: [String: Any]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if memo.count > 400 { memo.removeAll() }
        memo[k] = (Date(), v)
    }

    /// Generic TMDB shelf (Android Discovery.tmdbRow): "trending/movie/day", "movie/upcoming",
    /// "discover/tv?…" → imdb-keyed Metas, `pages` deep, de-duplicated.
    static func row(kind: String, _ pathAndParams: String, pages: Int = 1) async -> [Meta] {
        let parts = pathAndParams.split(separator: "?", maxSplits: 1).map(String.init)
        let path = "/" + (parts.first ?? "")
        let params = parts.count > 1 ? parts[1] : ""
        let pageLists: [[Meta]] = await withTaskGroup(of: (Int, [Meta]).self) { g in
            for pg in 1...max(1, pages) {
                g.addTask {
                    let q = params.isEmpty ? "page=\(pg)" : params + "&page=\(pg)"
                    return (pg, await metas(results(await get(path, q)), kind: kind, limit: 20))
                }
            }
            var out: [(Int, [Meta])] = []
            for await x in g { out.append(x) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        var seen = Set<String>(), flat: [Meta] = []
        for l in pageLists { for m in l where !seen.contains(m.id) { seen.insert(m.id); flat.append(m) } }
        return flat
    }

    /// One TMDB page of a shelf path (Discover's load-more).
    static func rowPage(kind: String, _ pathAndParams: String, page: Int) async -> [Meta] {
        let parts = pathAndParams.split(separator: "?", maxSplits: 1).map(String.init)
        let path = "/" + (parts.first ?? "")
        let params = parts.count > 1 ? parts[1] : ""
        let q = params.isEmpty ? "page=\(page)" : params + "&page=\(page)"
        return await metas(results(await get(path, q)), kind: kind, limit: 20)
    }

    /// Theme shelf spanning both types (Android tmdbBoth): movies + shows interleaved.
    static func both(_ movieQuery: String, _ tvQuery: String, pages: Int = 2) async -> [Meta] {
        async let m = row(kind: "movie", movieQuery, pages: pages)
        async let t = row(kind: "tv", tvQuery, pages: pages)
        let (mv, tv) = (await m, await t)
        var out: [Meta] = [], seen = Set<String>()
        for i in 0..<max(mv.count, tv.count) {
            if i < mv.count, !seen.contains(mv[i].id) { seen.insert(mv[i].id); out.append(mv[i]) }
            if i < tv.count, !seen.contains(tv[i].id) { seen.insert(tv[i].id); out.append(tv[i]) }
        }
        return out
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26") ?? s
    }

    // ---- id resolution (cached for the app's life) ----
    // tmdb → imdb never changes, so it lives on disk across launches (a Home of 17 shelves is
    // ~1000 lookups the first time and none after).
    private static var imdbCache: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: "tmdbImdbMap") as? [String: String]) ?? [:]
    }()
    private static var imdbDirty = 0
    private static var tmdbCache: [String: Int] = [:]         // "movie/tt…" → 123
    private static let idLock = NSLock()

    /// tmdb → imdb via /{kind}/{id}/external_ids (kind = movie | tv).
    static func imdbId(kind: String, id: Int) async -> String? {
        let k = "\(kind)/\(id)"
        idLock.lock(); let hit = imdbCache[k]; idLock.unlock()
        if let c = hit { return c.isEmpty ? nil : c }
        let r = await get("/\(kind)/\(id)/external_ids")
        guard r != nil else { return nil }   // unreachable: don't cache a miss
        let imdb = r?["imdb_id"] as? String ?? ""
        idLock.lock()
        imdbCache[k] = imdb
        imdbDirty += 1
        if imdbDirty >= 25 { imdbDirty = 0; UserDefaults.standard.set(imdbCache, forKey: "tmdbImdbMap") }
        idLock.unlock()
        return imdb.hasPrefix("tt") ? imdb : nil
    }

    /// imdb → tmdb id via /find (movie_results / tv_results). kind = movie | tv.
    static func tmdbId(kind: String, imdb: String) async -> Int? {
        let k = "\(kind)/\(imdb)"
        idLock.lock(); let hit = tmdbCache[k]; idLock.unlock()
        if let c = hit { return c > 0 ? c : nil }
        guard let r = await get("/find/\(imdb)", "external_source=imdb_id") else { return nil }
        let arr = r[kind == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]] ?? []
        let id = arr.first?["id"] as? Int ?? 0
        idLock.lock(); tmdbCache[k] = id; idLock.unlock()
        return id > 0 ? id : nil
    }

    /// A TMDB result row (movie or tv) → Meta with the IMDb id. Nil when it has no imdb id.
    static func meta(_ o: [String: Any], kind: String) async -> Meta? {
        guard let id = o["id"] as? Int, let imdb = await imdbId(kind: kind, id: id) else { return nil }
        var m: [String: Any] = ["id": imdb, "type": kind == "tv" ? "series" : "movie",
                                "name": o["title"] as? String ?? o["name"] as? String ?? ""]
        m["poster"] = img(o["poster_path"] as? String) ?? ""
        m["background"] = img(o["backdrop_path"] as? String, "w780") ?? ""
        m["description"] = o["overview"] as? String ?? ""
        let date = (o["release_date"] as? String ?? o["first_air_date"] as? String ?? "")
        if date.count >= 4 { m["releaseInfo"] = String(date.prefix(4)) }
        if let v = o["vote_average"] as? Double, v > 0 { m["imdbRating"] = String(format: "%.1f", v) }
        return Meta(m, type: kind == "tv" ? "series" : "movie")
    }

    /// Resolve a result list to Metas concurrently, keeping TMDB's order, dropping imdb-less rows.
    static func metas(_ rows: [[String: Any]], kind: String, limit: Int = 30) async -> [Meta] {
        let rows = Array(rows.prefix(limit))
        return await withTaskGroup(of: (Int, Meta?).self) { g in
            for (i, o) in rows.enumerated() { g.addTask { (i, await meta(o, kind: kind)) } }
            var out: [(Int, Meta)] = []
            for await (i, m) in g { if let m { out.append((i, m)) } }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    static func results(_ r: [String: Any]?) -> [[String: Any]] { r?["results"] as? [[String: Any]] ?? [] }

    // ---- catalogs ----
    static func trending(kind: String) async -> [Meta] {
        await metas(results(await get("/trending/\(kind)/week")), kind: kind)
    }
    /// Trending today (the desktop's Top 10 Today source).
    static func trendingDay(kind: String) async -> [Meta] {
        await metas(results(await get("/trending/\(kind)/day")), kind: kind, limit: 12)
    }
    static func discover(kind: String, _ query: String, page: Int = 1) async -> [Meta] {
        await metas(results(await get("/discover/\(kind)", query + "&page=\(page)")), kind: kind, limit: 20)
    }
    /// Anime = Animation ∩ Japanese origin (IOS_CONTRACTS §1a).
    static func anime(kind: String, page: Int = 1) async -> [Meta] {
        await discover(kind: kind, "with_genres=16&with_origin_country=JP&sort_by=popularity.desc", page: page)
    }
    static func search(kind: String, _ q: String) async -> [Meta] {
        await metas(results(await get("/search/\(kind)", "query=\(enc(q))&include_adult=false")), kind: kind, limit: 20)
    }

    // ---- genres (TMDB ids; Cinemeta names layer onto discover via with_genres) ----
    static let movieGenres: [(String, Int)] = [
        ("Action", 28), ("Adventure", 12), ("Animation", 16), ("Comedy", 35), ("Crime", 80),
        ("Documentary", 99), ("Drama", 18), ("Family", 10751), ("Fantasy", 14), ("History", 36),
        ("Horror", 27), ("Music", 10402), ("Mystery", 9648), ("Romance", 10749), ("Sci-Fi", 878),
        ("Thriller", 53), ("War", 10752), ("Western", 37)]
    static let tvGenres: [(String, Int)] = [
        ("Action", 10759), ("Adventure", 10759), ("Animation", 16), ("Comedy", 35), ("Crime", 80),
        ("Documentary", 99), ("Drama", 18), ("Family", 10751), ("Kids", 10762), ("Mystery", 9648),
        ("News", 10763), ("Reality", 10764), ("Sci-Fi", 10765), ("Fantasy", 10765), ("Soap", 10766),
        ("Talk", 10767), ("War", 10768), ("Western", 37)]
    static func genreId(_ name: String, kind: String) -> Int? {
        let list = kind == "tv" ? tvGenres : movieGenres
        let n = name.lowercased()
        return list.first { $0.0.lowercased() == n || n.hasPrefix($0.0.lowercased()) }?.1
    }
    static let years: [Int] = Array((1950...Calendar.current.component(.year, from: Date())).reversed())

    // ---- recommendations (guest For You rec graph, §1b) ----
    /// Seeds = the person's own library (continue + watchlist + watched), up to 8 strongest per
    /// kind. Consensus rank: how many seeds recommend a candidate, then vote count, then
    /// popularity; anything already in the library is dropped.
    static func recommendations(seeds: [Meta], exclude: Set<String>, kind: String) async -> [Meta] {
        let mine = Array(seeds.filter { ($0.type == "series") == (kind == "tv") }.prefix(8))
        guard !mine.isEmpty else { return [] }
        var score: [Int: (count: Int, votes: Int, pop: Double, row: [String: Any])] = [:]
        await withTaskGroup(of: [[String: Any]].self) { g in
            for s in mine {
                g.addTask {
                    guard let id = await tmdbId(kind: kind, imdb: s.id) else { return [] }
                    return results(await get("/\(kind)/\(id)/recommendations"))
                }
            }
            for await rows in g {
                for o in rows {
                    guard let id = o["id"] as? Int else { continue }
                    var e = score[id] ?? (0, o["vote_count"] as? Int ?? 0, o["popularity"] as? Double ?? 0, o)
                    e.count += 1
                    score[id] = e
                }
            }
        }
        let ranked = score.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.votes != $1.votes { return $0.votes > $1.votes }
            return $0.pop > $1.pop
        }.map { $0.row }
        return await metas(ranked, kind: kind, limit: 24).filter { !exclude.contains($0.id) }
    }

    // ---- where to watch (§1c) ----
    struct Providers {
        var stream: [String] = [], rent: [String] = [], buy: [String] = []
        var link: String? = nil
        var isEmpty: Bool { stream.isEmpty && rent.isEmpty && buy.isEmpty }
    }
    static func providers(imdb: String, kind: String) async -> Providers? {
        guard let id = await tmdbId(kind: kind, imdb: imdb),
              let r = await get("/\(kind)/\(id)/watch/providers"),
              let us = (r["results"] as? [String: Any])?["US"] as? [String: Any] else { return nil }
        func names(_ k: String) -> [String] {
            (us[k] as? [[String: Any]] ?? []).compactMap { $0["provider_name"] as? String }
        }
        var p = Providers()
        p.stream = names("flatrate"); p.rent = names("rent"); p.buy = names("buy")
        p.link = us["link"] as? String
        return p
    }

    // ---- people (§1 people search) ----
    struct Person: Identifiable, Hashable {
        let id: Int, name: String, profile: String?, known: String
    }
    static func people(_ q: String) async -> [Person] {
        results(await get("/search/person", "query=\(enc(q))&include_adult=false")).compactMap { o in
            guard let id = o["id"] as? Int, let n = o["name"] as? String else { return nil }
            return Person(id: id, name: n, profile: img(o["profile_path"] as? String, "w185"),
                          known: o["known_for_department"] as? String ?? "")
        }
    }
    /// Filmography: combined credits (cast + crew) newest first, resolved to imdb ids.
    static func filmography(_ id: Int) async -> [Meta] {
        guard let r = await get("/person/\(id)/combined_credits") else { return [] }
        var rows = (r["cast"] as? [[String: Any]] ?? []) + (r["crew"] as? [[String: Any]] ?? [])
        var seen = Set<Int>()
        rows = rows.filter { o in
            guard let i = o["id"] as? Int, !seen.contains(i) else { return false }
            seen.insert(i); return true
        }
        rows.sort { ($0["popularity"] as? Double ?? 0) > ($1["popularity"] as? Double ?? 0) }
        return await withTaskGroup(of: (Int, Meta?).self) { g in
            for (i, o) in rows.prefix(40).enumerated() {
                let kind = (o["media_type"] as? String) == "tv" ? "tv" : "movie"
                g.addTask { (i, await meta(o, kind: kind)) }
            }
            var out: [(Int, Meta)] = []
            for await (i, m) in g { if let m { out.append((i, m)) } }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}
