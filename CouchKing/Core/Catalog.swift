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

// A title as the addon/Cinemeta describe it. Only id/type/name/poster round-trip into the
// synced state blobs; the rest (backdrop, logo, genres…) feed the hero + Details header.
struct Meta: Identifiable, Hashable {
    let id: String, type: String, name: String, poster: String?
    var background: String? = nil
    var logo: String? = nil
    var description: String? = nil
    var genres: [String] = []
    var releaseInfo: String? = nil
    var imdbRating: String? = nil
    var runtime: String? = nil
    init?(_ o: [String: Any], type fallback: String) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        type = o["type"] as? String ?? fallback
        name = o["name"] as? String ?? ""
        poster = o["poster"] as? String
        background = o["background"] as? String
        logo = o["logo"] as? String
        description = o["description"] as? String
        genres = o["genres"] as? [String] ?? (o["genre"] as? [String] ?? [])
        releaseInfo = o["releaseInfo"] as? String ?? (o["year"] as? Int).map(String.init)
        if let r = o["imdbRating"] as? String { imdbRating = r }
        else if let r = o["imdbRating"] as? Double { imdbRating = String(format: "%.1f", r) }
        runtime = o["runtime"] as? String
    }
    init(id: String, type: String, name: String, poster: String?) {
        self.id = id; self.type = type; self.name = name; self.poster = poster
    }
    /// Round-trips into the synced state blobs (watchlist/continue/watched entries).
    var dict: [String: Any] { ["id": id, "type": type, "name": name, "poster": poster ?? ""] }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(type) }
    static func == (a: Meta, b: Meta) -> Bool { a.id == b.id && a.type == b.type }
}

/// One catalog the addon manifest advertises (Android reads the same list to build the shelf
/// lineup, find the "for you" rows and the Live TV `tv` catalog — nothing is hardcoded).
struct AddonCatalog: Identifiable, Hashable {
    let type: String, cid: String, name: String
    let genres: [String]          // manifest `extra` genre options → Discover dropdown / Live chips
    let searchOnly: Bool          // extra search REQUIRED = not a browsable shelf
    var curated: [String] = []    // ordered IMDb ids for a watch-order row (never shuffled)
    var shelf: Shelf? = nil       // a Home shelf from the shared Discovery.SHELF_CATALOG
    var id: String { type + "/" + cid }
    /// A curated watch-order shelf (IOS_CONTRACTS §3).
    init(curated name: String, cid: String, ids: [String]) {
        type = "movie"; self.cid = cid; self.name = name
        genres = []; searchOnly = false; curated = ids
    }
    /// A shelf-catalog row (Android Discovery.Row) as a Home shelf.
    init(shelf: Shelf) {
        type = shelf.type; cid = "shelf:" + shelf.label; name = shelf.label
        genres = []; searchOnly = false; curated = shelf.ids
        self.shelf = shelf
    }
    init?(_ o: [String: Any]) {
        guard let t = o["type"] as? String, let c = o["id"] as? String else { return nil }
        type = t; cid = c
        name = o["name"] as? String ?? c
        var g: [String] = []
        var so = false
        for e in o["extra"] as? [[String: Any]] ?? [] {
            let n = e["name"] as? String ?? ""
            if n == "genre" { g = e["options"] as? [String] ?? [] }
            if n == "search", e["isRequired"] as? Bool == true { so = true }
        }
        if let props = o["extraRequired"] as? [String], props.contains("search") { so = true }
        if g.isEmpty, let gs = o["genres"] as? [String] { g = gs }
        genres = g; searchOnly = so
    }
    var isForYou: Bool { name.lowercased().contains("for you") || cid.lowercased().contains("foryou") }
    var isLive: Bool { type == "tv" }
    /// Curated watch-order rows (Marvel chronological etc.) render in EXACT order — never shuffled.
    var isOrdered: Bool {
        let n = name.lowercased()
        return n.contains("order") || n.contains("chronolog") || n.contains("timeline") || n.contains("saga")
    }
    /// A shelf the user can enable on Home: browsable movie/series catalog that isn't For You.
    var isShelf: Bool { !isLive && !searchOnly && !isForYou && (type == "movie" || type == "series") }
}


/// One Home shelf (Android Discovery.Row / desktop CK_CAT.SHELF_CATALOG): a Cinemeta catalog
/// (optionally genre-filtered), a TMDB query (+ a TV query for theme rows that mix both types),
/// or an exact ordered imdb-id list.
struct Shelf: Hashable {
    let label: String, type: String
    var cine: String = ""          // Cinemeta catalog id ("top" / "year" / "imdbRating")
    var genre: String? = nil
    var tmdb: String? = nil        // TMDB path + params, e.g. "discover/movie?with_genres=27"
    var tmdbTv: String? = nil      // theme shelf: also this TV query, interleaved
    var ids: [String] = []         // curated watch order — rendered as-is, never shuffled
    var tmdbKind: String { type == "series" ? "tv" : "movie" }
}

// The SAME shelves, queries and order as the Firestick / web / desktop apps, so the synced
// `shelves` labels mean the same rows everywhere.
enum ShelfCatalog {
    private static func prov(_ kind: String, _ ids: String) -> String {
        "discover/\(kind)?with_watch_providers=\(ids)&watch_region=US&sort_by=popularity.desc"
    }
    /// True "in theaters now": a primary_release_date window (TMDB now_playing counts re-releases).
    static func nowPlaying() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let gte = f.string(from: Date().addingTimeInterval(-75 * 86400))
        let lte = f.string(from: Date().addingTimeInterval(3 * 86400))
        return "discover/movie?sort_by=popularity.desc&with_release_type=3|2&region=US&vote_count.gte=3"
            + "&primary_release_date.gte=\(gte)&primary_release_date.lte=\(lte)"
    }
    private static func tm(_ l: String, _ t: String, _ q: String, tv: String? = nil) -> Shelf {
        Shelf(label: l, type: t, tmdb: q, tmdbTv: tv)
    }
    private static func cine(_ l: String, _ t: String, _ id: String, _ g: String? = nil) -> Shelf {
        Shelf(label: l, type: t, cine: id, genre: g)
    }

    static let all: [Shelf] = [
        tm("Coming Soon", "movie", "movie/upcoming"),
        tm("Trending Today", "movie", "trending/movie/day"),
        tm("Christmas Movies", "movie", "discover/movie?with_keywords=207317&sort_by=popularity.desc"),
        tm("Halloween Movies", "movie", "discover/movie?with_keywords=3335&sort_by=popularity.desc"),
        tm("Date Night", "movie", "discover/movie?with_genres=10749,35&sort_by=popularity.desc&vote_count.gte=200",
           tv: "discover/tv?with_genres=35&sort_by=popularity.desc&vote_count.gte=100"),
        tm("Superheroes", "movie", "discover/movie?with_keywords=9715&sort_by=popularity.desc&vote_count.gte=100",
           tv: "discover/tv?with_keywords=9715&sort_by=popularity.desc&vote_count.gte=20"),
        tm("Zombies", "movie", "discover/movie?with_keywords=12377&sort_by=popularity.desc&vote_count.gte=50",
           tv: "discover/tv?with_keywords=12377&sort_by=popularity.desc&vote_count.gte=15"),
        tm("Time Travel", "movie", "discover/movie?with_keywords=4379&sort_by=popularity.desc&vote_count.gte=100",
           tv: "discover/tv?with_keywords=4379&sort_by=popularity.desc&vote_count.gte=15"),
        tm("Feel-Good", "movie", "discover/movie?with_genres=35,10751&sort_by=popularity.desc&vote_count.gte=300",
           tv: "discover/tv?with_genres=35,10751&sort_by=popularity.desc&vote_count.gte=100"),
        tm("Tearjerkers", "movie", "discover/movie?with_genres=18,10749&sort_by=vote_average.desc&vote_count.gte=500",
           tv: "discover/tv?with_genres=18&sort_by=vote_average.desc&vote_count.gte=200"),
        tm("Summer Blockbusters", "movie", "discover/movie?with_genres=28,12&sort_by=popularity.desc&vote_count.gte=1000",
           tv: "discover/tv?with_genres=10759&sort_by=popularity.desc&vote_count.gte=200"),
        tm("Fantasy Worlds", "movie", "discover/movie?with_genres=14&sort_by=popularity.desc&vote_count.gte=300",
           tv: "discover/tv?with_genres=10765&sort_by=popularity.desc&vote_count.gte=100"),
        tm("War Movies", "movie", "discover/movie?with_genres=10752&sort_by=popularity.desc&vote_count.gte=200"),
        tm("Musicals", "movie", "discover/movie?with_genres=10402&sort_by=popularity.desc&vote_count.gte=100"),
        tm("Cozy Mystery Series", "series", "discover/tv?with_genres=9648&sort_by=popularity.desc&vote_count.gte=50"),
        tm("True Crime", "series", "discover/tv?with_genres=99,80&sort_by=popularity.desc"),
        tm("Based on a True Story", "movie", "discover/movie?with_keywords=9672&sort_by=popularity.desc"),
        tm("Classics", "movie", "discover/movie?primary_release_date.lte=1989-12-31&sort_by=vote_count.desc"),
        tm("90s Throwbacks", "movie", "discover/movie?primary_release_date.gte=1990-01-01&primary_release_date.lte=1999-12-31&sort_by=vote_count.desc"),
        tm("Kids Movies", "movie", "discover/movie?with_genres=16,10751&sort_by=popularity.desc&certification_country=US&certification.lte=PG"),
        cine("Westerns", "movie", "top", "Western"),
        cine("Mystery", "movie", "top", "Mystery"),
        tm("Kids TV", "series", "discover/tv?with_genres=10762&sort_by=popularity.desc"),
        cine("Popular Movies", "movie", "top"),
        cine("Popular Series", "series", "top"),
        tm("New in Theaters", "movie", nowPlaying()),
        tm("🍅 Certified Fresh", "movie", "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc"),
        tm("🍅 Certified Fresh Series", "series", "discover/tv?vote_average.gte=7.7&vote_count.gte=200&sort_by=popularity.desc"),
        tm("Trending Movies", "movie", "trending/movie/week"),
        tm("Trending Series", "series", "trending/tv/week"),
        tm("New Shows", "series", "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25"),
        cine("Top Rated Movies", "movie", "imdbRating"),
        cine("Top Rated Series", "series", "imdbRating"),
        tm("Anime", "series", "discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc"),
        tm("Anime Movies", "movie", "discover/movie?with_genres=16&with_origin_country=JP&sort_by=popularity.desc"),
        tm("Hallmark", "movie", "discover/movie?with_companies=53015|304438&sort_by=popularity.desc"),
        tm("Hallmark New", "movie", "discover/movie?with_companies=53015|304438&sort_by=primary_release_date.desc&vote_count.gte=1"),
        tm("Hallmark Series", "series", "discover/tv?with_networks=384&sort_by=popularity.desc"),
        tm("Hallmark Christmas Movies", "movie", "discover/movie?with_companies=53015|304438&with_keywords=207317&sort_by=popularity.desc"),
        Shelf(label: "Marvel: Release Order", type: "movie", ids: Curated.mcuRelease),
        Shelf(label: "Marvel: Chronological", type: "movie", ids: Curated.mcuChrono),
        tm("Marvel Movies", "movie", "discover/movie?with_companies=420&sort_by=popularity.desc"),
        tm("Marvel Series", "series", "discover/tv?with_companies=420|7505&sort_by=popularity.desc"),
        Shelf(label: "X-Men Movies", type: "movie", ids: Curated.xmen),
        tm("Netflix", "series", prov("tv", "8")),
        tm("Hulu", "series", prov("tv", "15")),
        tm("Disney+", "series", prov("tv", "337")),
        tm("Max", "series", prov("tv", "1899")),
        tm("Prime Video", "movie", prov("movie", "9")),
        tm("Apple TV+", "series", prov("tv", "350")),
        tm("Paramount+", "series", prov("tv", "2303|2616|531")),
        tm("Peacock", "series", prov("tv", "386")),
        cine("Action", "movie", "top", "Action"),
        cine("Comedy", "movie", "top", "Comedy"),
        cine("Horror", "movie", "top", "Horror"),
        cine("Sci-Fi", "movie", "top", "Sci-Fi"),
        cine("Romance", "movie", "top", "Romance"),
        cine("Thriller", "movie", "top", "Thriller"),
        cine("Drama Series", "series", "top", "Drama"),
        cine("Crime Series", "series", "top", "Crime"),
        cine("Reality", "series", "top", "Reality-TV"),
        cine("Documentary", "movie", "top", "Documentary"),
        cine("Family", "movie", "top", "Family"),
    ]

    /// Default Home (Android DEFAULT_SHELVES): trending/popular basics, every streaming
    /// service row, and a couple of broad crowd-pleasers.
    static let defaults = ["Trending Today", "Trending Series", "Popular Movies", "Popular Series",
                           "New in Theaters", "Coming Soon",
                           "Netflix", "Hulu", "Disney+", "Max", "Prime Video", "Apple TV+", "Paramount+", "Peacock",
                           "Top Rated Movies", "Top Rated Series", "True Crime"]

    /// Shelf-picker groups (Android showShelfPicker sections).
    static let providers = ["Netflix", "Hulu", "Disney+", "Max", "Prime Video", "Apple TV+", "Paramount+", "Peacock"]
    static let channels = ["Hallmark", "Hallmark New", "Hallmark Series", "Hallmark Christmas Movies",
                           "Anime", "Anime Movies",
                           "Marvel: Release Order", "Marvel: Chronological", "Marvel Movies", "Marvel Series", "X-Men Movies"]
    static let moods = ["Christmas Movies", "Halloween Movies", "Date Night", "True Crime",
                        "Based on a True Story", "Classics", "90s Throwbacks", "Kids Movies", "Kids TV",
                        "Superheroes", "Zombies", "Time Travel", "Feel-Good", "Tearjerkers",
                        "Summer Blockbusters", "Fantasy Worlds", "War Movies", "Musicals", "Cozy Mystery Series"]
    static let genres = ["Action", "Comedy", "Horror", "Sci-Fi", "Romance", "Thriller",
                         "Drama Series", "Crime Series", "Reality", "Documentary", "Family"]
    /// (section title, shelves) in picker order: POPULAR & NEW · MOODS & SEASONS · STREAMING
    /// SERVICES · CHANNELS & ANIME · GENRES.
    static var groups: [(String, [Shelf])] {
        let grouped = Set(providers + channels + moods + genres)
        return [("POPULAR & NEW", all.filter { !grouped.contains($0.label) }),
                ("MOODS & SEASONS", all.filter { moods.contains($0.label) }),
                ("STREAMING SERVICES", all.filter { providers.contains($0.label) }),
                ("CHANNELS & ANIME", all.filter { channels.contains($0.label) }),
                ("GENRES", all.filter { genres.contains($0.label) })].filter { !$0.1.isEmpty }
    }
}

// Curated watch-order rows (IOS_CONTRACTS §3 / Android Discovery.SHELF_CATALOG `ids` rows):
// exact ordered IMDb id lists, resolved to Cinemeta metas, rendered UNSHUFFLED.
enum Curated {
    static func ids(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) }
    static var mcuRelease: [String] { shelves[0].curated }
    static var mcuChrono: [String] { shelves[1].curated }
    static var xmen: [String] { shelves[2].curated }
    static let shelves: [AddonCatalog] = [
        AddonCatalog(curated: "Marvel: Release Order", cid: "ck-order-marvel-release", ids: ids("""
        tt0371746 tt0800080 tt1228705 tt0800369 tt0458339 tt0848228 tt1300854 tt1981115 tt1843866
        tt2015381 tt2395427 tt0478970 tt3498820 tt1211837 tt3896198 tt2250912 tt3501632 tt1825683
        tt4154756 tt5095030 tt4154664 tt4154796 tt6320628 tt9140560 tt9208876 tt9140554 tt3480822
        tt10168312 tt9376612 tt9032400 tt10160804 tt10872600 tt10234724 tt9419884 tt10857164
        tt10648342 tt10857160 tt9114286 tt10954600 tt6791350 tt13157618 tt10676048 tt13966962
        tt6263850 tt15571732 tt14513804 tt18923754 tt20969586 tt13623126 tt10676052 tt16027014
        tt21066182 tt22084616 tt23112594 tt21357150 tt21361444
        """)),
        AddonCatalog(curated: "Marvel: Chronological", cid: "ck-order-marvel-chrono", ids: ids("""
        tt0458339 tt4154664 tt0371746 tt1228705 tt0800080 tt0800369 tt0848228 tt1300854 tt1981115
        tt1843866 tt2015381 tt3896198 tt2395427 tt0478970 tt3498820 tt3480822 tt1825683 tt2250912
        tt1211837 tt3501632 tt5095030 tt4154756 tt4154796 tt6320628 tt9140560 tt9208876 tt9376612
        tt9032400 tt10872600 tt10160804 tt9140554 tt10168312 tt10234724 tt9419884 tt10857164
        tt10648342 tt10857160 tt9114286 tt13157618 tt10954600 tt6791350 tt10676048 tt13966962
        tt6263850 tt15571732 tt14513804 tt18923754 tt20969586 tt13623126 tt10676052 tt16027014
        tt21066182 tt22084616 tt23112594 tt21357150 tt21361444
        """)),
        AddonCatalog(curated: "X-Men Movies", cid: "ck-order-xmen", ids: ids("""
        tt0120903 tt0290334 tt0376994 tt0458525 tt1270798 tt1430132 tt1877832 tt1431045 tt3385516
        tt3315342 tt5463162 tt6565702 tt4682266 tt6263850
        """)),
    ]

    // MainActor-guarded: row() resolves CONCURRENTLY and every task read/wrote this dict
    // unsynchronized — Dictionary corruption = the intermittent cold-open SIGSEGV on the
    // curated shelves (Oct 5 b34, crumb=home-shelf:Marvel: Release Order). resolve hops to
    // the main actor only for the dict touch; the network awaits still run concurrently.
    @MainActor private static var cache: [String: Meta] = [:]

    /// Resolve one id: Cinemeta meta for the row's type, then the other type, then TMDB /find.
    @MainActor
    static func resolve(_ id: String, type: String) async -> Meta? {
        if let c = cache[id] { return c }
        for t in [type, type == "movie" ? "series" : "movie"] {
            if let r = try? await API.json("/meta/\(t)/\(id).json", base: Catalog.cinemeta),
               let m = r["meta"] as? [String: Any], let meta = Meta(m, type: t) {
                cache[id] = meta; return meta
            }
        }
        for kind in ["movie", "tv"] {
            if let r = await TMDB.get("/find/\(id)", "external_source=imdb_id"),
               let o = (r[kind == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
               let m = await TMDB.meta(o, kind: kind) {
                cache[id] = m; return m
            }
        }
        return nil
    }

    /// The whole row, in list order (concurrent resolves, missing ids dropped).
    static func row(_ c: AddonCatalog) async -> [Meta] {
        await withTaskGroup(of: (Int, Meta?).self) { g in
            for (i, id) in c.curated.enumerated() { g.addTask { (i, await resolve(id, type: c.type)) } }
            var out: [(Int, Meta)] = []
            for await (i, m) in g { if let m { out.append((i, m)) } }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}

struct Catalog {
    static let cinemeta = "https://v3-cinemeta.strem.io"

    /// per-profile, per-day shuffle of a category row (Android profileMix): stable all day,
    /// fresh tomorrow, and different per person.
    @MainActor
    static func mix(_ metas: [Meta], session: Session, salt: String) -> [Meta] {
        let day = Int(Date().timeIntervalSince1970 / 86400)
        let who = session.currentProfile.isEmpty ? "guest" : session.currentProfile
        var gen = SeededGen(fnv("\(who)|\(day)|\(salt)"))
        return metas.shuffled(using: &gen)
    }

    static func metas(_ r: [String: Any]?, type: String) -> [Meta] {
        (r?["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: type) }
    }

    /// Fetch one catalog page from the user's addon, profile identity carried the Android way
    /// (config-segment userName via withUser) plus the `?u=` query the service also honors.
    /// A shelf's row: curated lists resolve through Cinemeta; everything else hits the addon.
    @MainActor
    static func shelf(session: Session, _ c: AddonCatalog) async -> [Meta] {
        if let sh = c.shelf { return await shelfRow(session: session, sh) }
        if !c.curated.isEmpty { return await Curated.row(c) }
        return await fetch(session: session, type: c.type, cid: c.cid)
    }

    /// One Home shelf exactly as Android buildShelvesInto fills it: curated ids in order; a
    /// theme shelf = movies + shows interleaved (2 pages each); a TMDB shelf = 3 pages; a
    /// Cinemeta shelf = 2 pages (TMDB stands in when Cinemeta can't be reached). Category
    /// rows get the per-profile daily shuffle; curated lists never do.
    @MainActor
    static func shelfRow(session: Session, _ sh: Shelf) async -> [Meta] {
        if !sh.ids.isEmpty {
            return await Curated.row(AddonCatalog(curated: sh.label, cid: sh.cine, ids: sh.ids))
        }
        let items: [Meta]
        if let q = sh.tmdb, let tvq = sh.tmdbTv {
            items = await TMDB.both(q, tvq, pages: 2)
        } else if let q = sh.tmdb {
            items = await TMDB.row(kind: sh.tmdbKind, q, pages: 3)
        } else {
            items = await cinemeta(type: sh.type, id: sh.cine.isEmpty ? "top" : sh.cine, genre: sh.genre, pages: 2)
        }
        return mix(items, session: session, salt: sh.label)
    }

    /// Cinemeta catalog pages (100 per page, `skip=N`), TMDB fallback when Cinemeta is
    /// unreachable — an EMPTY Cinemeta answer stays empty (Android Discovery.catalog).
    static func cinemeta(type: String, id: String, genre: String? = nil, pages: Int = 1) async -> [Meta] {
        var reached = false
        var out: [Meta] = []
        var seen = Set<String>()
        await withTaskGroup(of: (Int, [Meta]?).self) { g in
            for pg in 0..<pages {
                g.addTask {
                    var seg = ""
                    if let genre, pg == 0 { seg = "/genre=" + enc(genre) }
                    else if pg > 0 { seg = "/" + (genre.map { "genre=\(enc($0))&" } ?? "") + "skip=\(pg * 100)" }
                    guard let r = try? await API.json("/catalog/\(type)/\(id)\(seg).json", base: cinemeta) else { return (pg, nil) }
                    return (pg, metas(r, type: type))
                }
            }
            var pagesOut: [(Int, [Meta])] = []
            for await (pg, m) in g { if let m { reached = true; pagesOut.append((pg, m)) } }
            for (_, m) in pagesOut.sorted(by: { $0.0 < $1.0 }) {
                for x in m where !seen.contains(x.id) { seen.insert(x.id); out.append(x) }
            }
        }
        if reached { return out }
        let kind = type == "series" ? "tv" : "movie"
        let path: String
        if let genre {
            let gid = TMDB.genreId(genre, kind: kind).map { "&with_genres=\($0)" } ?? ""
            path = "discover/\(kind)?sort_by=popularity.desc&vote_count.gte=40" + gid
        } else if id == "imdbRating" { path = "\(kind)/top_rated" }
        else { path = "\(kind)/popular" }
        return await TMDB.row(kind: kind, path, pages: pages)
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// One Cinemeta catalog page (`skip = page × 100`), for Discover's load-more.
    static func cinemetaPage(type: String, id: String, genre: String?, page: Int) async -> [Meta] {
        var seg = ""
        if let genre, page == 0 { seg = "/genre=" + enc(genre) }
        else if page > 0 { seg = "/" + (genre.map { "genre=\(enc($0))&" } ?? "") + "skip=\(page * 100)" }
        return metas(try? await API.json("/catalog/\(type)/\(id)\(seg).json", base: cinemeta), type: type)
    }

    @MainActor
    static func fetch(session: Session, type: String, cid: String, extra: String = "") async -> [Meta] {
        guard let base = session.addonBase() else { return [] }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let path = extra.isEmpty ? "/catalog/\(type)/\(cid).json?u=\(u)"
                                 : "/catalog/\(type)/\(cid)/\(extra).json?u=\(u)"
        return metas(try? await API.json(path, base: base), type: type)
    }

    /// The Home shelf lineup (Android buildShelvesInto): For You Movies/Shows first (manifest
    /// discovered — any catalog named "for you" per type), then the user's enabled shelves in
    /// THEIR order. Returned as (title, catalog) so the caller can fill rows top-down.
    @MainActor
    static func homeLineup(session: Session) -> [(String, AddonCatalog)] {
        var out: [(String, AddonCatalog)] = []
        for t in ["movie", "series"] {
            if let fy = session.catalogs.first(where: { $0.isForYou && $0.type == t }) {
                out.append((t == "movie" ? "For You — Movies" : "For You — Shows", fy))
            }
        }
        for c in session.enabledShelves() { out.append((c.name, c)) }
        return out
    }

    /// Guest / tracker Home (no addon): Cinemeta-powered discovery rows so the store-review
    /// experience is a complete app. (Android uses its TMDB rows here; TMDB needs the server-
    /// delivered key, so the key-free Cinemeta catalogs stand in with the same shape.)
    static let guestRows: [(String, String, String)] = [
        ("Trending Movies", "movie", "top"),
        ("Trending Shows", "series", "top"),
        ("Action Movies", "movie", "top/genre=Action"),
        ("Comedy Shows", "series", "top/genre=Comedy"),
        ("Documentaries", "series", "top/genre=Documentary"),
        ("Animation", "movie", "top/genre=Animation"),
    ]

    static func guestRow(_ type: String, _ path: String) async -> [Meta] {
        metas(try? await API.json("/catalog/\(type)/\(path).json", base: cinemeta), type: type)
    }

    /// Guest / tracker For You (IOS_CONTRACTS §1b): TMDB rec graph seeded by the person's own
    /// library, consensus-ranked, movie+TV interleaved; trending when there are no seeds/recs.
    @MainActor
    static func guestForYou(session: Session) async -> [Meta] {
        let seeds = session.librarySeeds()
        let mine = session.libraryIds()
        async let m = TMDB.recommendations(seeds: seeds, exclude: mine, kind: "movie")
        async let t = TMDB.recommendations(seeds: seeds, exclude: mine, kind: "tv")
        let (rm, rt) = (await m, await t)
        if !rm.isEmpty || !rt.isEmpty { return interleave(rm, rt, count: 30) }
        async let tm = TMDB.trending(kind: "movie")
        async let tt = TMDB.trending(kind: "tv")
        return interleave(await tm, await tt, count: 30).filter { !mine.contains($0.id) }
    }

    /// Trending movies + shows — the addon's trending catalogs when present, Cinemeta `top`
    /// for guests. Feeds Top 10 Today + the hero carousel.
    @MainActor
    static func trending(session: Session) async -> ([Meta], [Meta]) {
        // Android Home: TODAY's trending movies + shows from TMDB (hero carousel + Top 10),
        // independent of whichever shelf is first; Cinemeta `top` if TMDB is unreachable.
        async let m = TMDB.row(kind: "movie", "trending/movie/day", pages: 1)
        async let s = TMDB.row(kind: "tv", "trending/tv/day", pages: 1)
        var (mv, sv) = (await m, await s)
        if mv.isEmpty && sv.isEmpty {
            async let gm = guestRow("movie", "top")
            async let gs = guestRow("series", "top")
            (mv, sv) = (await gm, await gs)
        }
        return (mv, sv)
    }

    /// Android forYouRows: the addon's own For You catalog per type first, else the TMDB rec
    /// graph seeded by the person's library, else this week's trending.
    @MainActor
    static func forYouRows(session: Session) async -> ([Meta], [Meta]) {
        var mv: [Meta] = [], sv: [Meta] = []
        if session.hasAddon {
            if let fy = session.catalogs.first(where: { $0.isForYou && $0.type == "movie" }) { mv = await fetch(session: session, type: "movie", cid: fy.cid) }
            if let fy = session.catalogs.first(where: { $0.isForYou && $0.type == "series" }) { sv = await fetch(session: session, type: "series", cid: fy.cid) }
        }
        if mv.isEmpty || sv.isEmpty {
            let seeds = session.librarySeeds()
            let mine = session.libraryIds()
            if mv.isEmpty {
                mv = await TMDB.recommendations(seeds: seeds, exclude: mine, kind: "movie")
                if mv.isEmpty { mv = await TMDB.row(kind: "movie", "trending/movie/week", pages: 1) }
            }
            if sv.isEmpty {
                sv = await TMDB.recommendations(seeds: seeds, exclude: mine, kind: "tv")
                if sv.isEmpty { sv = await TMDB.row(kind: "tv", "trending/tv/week", pages: 1) }
            }
        }
        return (mv, sv)
    }

    /// Top 10 Today (Android addTop10Row): trending movies + shows interleaved, first 10.
    static func interleave(_ mv: [Meta], _ sv: [Meta], count: Int = 10) -> [Meta] {
        var out: [Meta] = []
        var i = 0
        while out.count < count && (i < mv.count || i < sv.count) {
            if i < mv.count { out.append(mv[i]) }
            if out.count < count && i < sv.count { out.append(sv[i]) }
            i += 1
        }
        return out
    }

    /// Full meta (videos, backdrop, logo, genres…) — addon first, Cinemeta as guest fallback.
    @MainActor
    static func fullMeta(session: Session, type: String, id: String) async -> [String: Any] {
        if let base = session.addonBase(),
           let r = try? await API.json("/meta/\(type)/\(id).json", base: base),
           let m = r["meta"] as? [String: Any] { return m }
        if let r = try? await API.json("/meta/\(type)/\(id).json", base: cinemeta),
           let m = r["meta"] as? [String: Any] { return m }
        return [:]
    }
}
