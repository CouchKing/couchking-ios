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
    var id: String { type + "/" + cid }
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
