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
    var id: String { type + "/" + cid }
    /// A curated watch-order shelf (IOS_CONTRACTS §3).
    init(curated name: String, cid: String, ids: [String]) {
        type = "movie"; self.cid = cid; self.name = name
        genres = []; searchOnly = false; curated = ids
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

// Curated watch-order rows (IOS_CONTRACTS §3 / Android Discovery.SHELF_CATALOG `ids` rows):
// exact ordered IMDb id lists, resolved to Cinemeta metas, rendered UNSHUFFLED.
enum Curated {
    static func ids(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) }
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

    private static var cache: [String: Meta] = [:]

    /// Resolve one id: Cinemeta meta for the row's type, then the other type, then TMDB /find.
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
        if !c.curated.isEmpty { return await Curated.row(c) }
        return await fetch(session: session, type: c.type, cid: c.cid)
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
        if session.addonBase() != nil {
            let mc = session.catalogs.first { $0.type == "movie" && $0.isShelf && $0.name.lowercased().contains("trending") }
            let sc = session.catalogs.first { $0.type == "series" && $0.isShelf && $0.name.lowercased().contains("trending") }
            async let m = fetch(session: session, type: "movie", cid: mc?.cid ?? "couchking-movies")
            async let s = fetch(session: session, type: "series", cid: sc?.cid ?? "couchking-series")
            return (await m, await s)
        }
        async let m = guestRow("movie", "top")
        async let s = guestRow("series", "top")
        return (await m, await s)
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
