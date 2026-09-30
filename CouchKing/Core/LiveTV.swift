import Foundation

// Live TV data layer (IOS_CONTRACTS.md §2): guide.json / fav / games.json on the user's own
// addon authority. All times are epoch ms, displayed in America/New_York like every client.
struct LiveProg: Hashable {
    let s: Int, e: Int, t: String
    init?(_ o: [String: Any]) {
        let s = StateMerge.stamp(o["s"]), e = StateMerge.stamp(o["e"])
        guard e > 0 else { return nil }
        self.s = s; self.e = e; t = o["t"] as? String ?? ""
    }
}

struct LiveChannel: Identifiable, Hashable {
    let id: String, name: String, logo: String, genre: String, section: String
    let progs: [LiveProg]
    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = o["name"] as? String ?? id
        logo = o["logo"] as? String ?? ""
        genre = o["genre"] as? String ?? ""
        section = o["section"] as? String ?? ""
        progs = (o["progs"] as? [[String: Any]] ?? []).compactMap(LiveProg.init)
    }
    /// Now/next are derived client-side: now = s <= at < e, next = first s > at.
    func now(_ at: Int) -> LiveProg? { progs.first { $0.s <= at && at < $0.e } }
    func next(_ at: Int) -> LiveProg? { progs.first { $0.s > at } }
    /// The play id (`cklive:` + channel id) as a Meta for the tune screen / stream sheet.
    func meta(_ at: Int) -> Meta {
        var m = Meta(id: id.hasPrefix("cklive:") ? id : "cklive:" + id, type: "tv", name: name, poster: logo.isEmpty ? nil : logo)
        m.logo = logo.isEmpty ? nil : logo
        m.description = now(at)?.t
        return m
    }
    static func == (a: LiveChannel, b: LiveChannel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct LiveGuide {
    var at = 0, devices = 0
    var favs: [String] = []
    var favChannels: [LiveChannel] = []
    var recent: [String] = []
    var channels: [LiveChannel] = []
    var sections: [String] {
        var out: [String] = []
        for c in channels where !c.section.isEmpty && !out.contains(c.section) { out.append(c.section) }
        return out
    }
    init() {}
    init(_ o: [String: Any]) {
        at = StateMerge.stamp(o["at"]); devices = StateMerge.stamp(o["devices"])
        favs = o["favs"] as? [String] ?? []
        favChannels = (o["favChannels"] as? [[String: Any]] ?? []).compactMap(LiveChannel.init)
        recent = o["recent"] as? [String] ?? []
        channels = (o["channels"] as? [[String: Any]] ?? []).compactMap(LiveChannel.init)
    }
}

struct LiveGame: Identifiable, Hashable {
    let t: String, ch: String, chid: String, logo: String, s: Int, e: Int, when: String, rg: String
    var id: String { chid + "|" + String(s) }
    init?(_ o: [String: Any]) {
        guard let chid = o["chid"] as? String else { return nil }
        self.chid = chid
        t = o["t"] as? String ?? ""; ch = o["ch"] as? String ?? ""
        logo = o["logo"] as? String ?? ""
        s = StateMerge.stamp(o["s"]); e = StateMerge.stamp(o["e"])
        when = o["when"] as? String ?? ""; rg = o["rg"] as? String ?? "US"
    }
    var meta: Meta {
        var m = Meta(id: chid, type: "tv", name: t.isEmpty ? ch : t, poster: logo.isEmpty ? nil : logo)
        m.description = ch
        return m
    }
}

/// An upcoming game with its sport's emoji (the merged "📅 Upcoming games" strip).
struct EmojiGame: Identifiable {
    let emoji: String, game: LiveGame
    var id: String { game.id }
}

struct LiveSport: Identifiable {
    let sport: String, emoji: String
    let live: [LiveGame], soon: [LiveGame]
    var id: String { sport }
    init(sport: String, emoji: String, live: [LiveGame], soon: [LiveGame]) {
        self.sport = sport; self.emoji = emoji; self.live = live; self.soon = soon
    }
    init?(_ o: [String: Any], now: Int) {
        guard let s = o["sport"] as? String else { return nil }
        sport = s; emoji = o["emoji"] as? String ?? ""
        live = (o["live"] as? [[String: Any]] ?? []).compactMap(LiveGame.init).filter { $0.e > now }
        soon = (o["soon"] as? [[String: Any]] ?? []).compactMap(LiveGame.init).filter { $0.e > now }
    }
}

enum LiveTV {
    static let et = TimeZone(identifier: "America/New_York") ?? .current
    static let regions: [(String, String)] = [("", "🌎 USA"), ("UK", "🇬🇧 UK"), ("CA", "🇨🇦 Canada")]
    static let sportsOrder = ["Football", "Baseball", "Basketball", "Hockey", "Fights", "Fútbol", "Tennis", "Golf", "More Sports"]

    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// "8:30 PM" in ET.
    static func clock(_ ms: Int) -> String {
        let f = DateFormatter(); f.timeZone = et; f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    /// "Wed" / "Sep 30" in ET.
    static func day(_ ms: Int, _ fmt: String = "EEE") -> String {
        let f = DateFormatter(); f.timeZone = et; f.dateFormat = fmt
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Host = the addon authority; key = subKey UPPERCASED; profile = the per-profile id (≤24).
    @MainActor
    static func host(_ session: Session) -> String? {
        guard let a = session.addons.first, let u = URL(string: a.url), let h = u.host else { return nil }
        var s = (u.scheme ?? "https") + "://" + h
        if let p = u.port { s += ":\(p)" }
        return s
    }
    @MainActor
    static func key(_ session: Session) -> String { session.subKey.uppercased() }
    @MainActor
    static func profile(_ session: Session) -> String { String(session.currentProfile.prefix(24)) }

    private static var guideCache: [String: (Int, LiveGuide)] = [:]   // region → (fetched ms, guide)
    private static var gamesCache: (Int, [LiveSport])? = nil

    /// GET /live/{KEY}/guide.json?p=&r= — cached ~55s per region; `force` bypasses (fav/recent
    /// dirty). Returns nil on network failure, `.locked` when the key is invalid/expired (403).
    enum GuideResult { case ok(LiveGuide), locked, failed }
    @MainActor
    static func guide(_ session: Session, region: String, force: Bool = false) async -> GuideResult {
        guard let h = host(session) else { return .failed }
        let k = key(session)
        guard !k.isEmpty else { return .failed }
        if !force, let c = guideCache[region], nowMs() - c.0 < 55_000 { return .ok(c.1) }
        let p = profile(session).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = try? await API.jsonStatus("/live/\(k)/guide.json?p=\(p)&r=\(region)", base: h) else { return .failed }
        if r.1 == 403 { return .locked }
        guard r.1 == 200 else { return .failed }
        let g = LiveGuide(r.0)
        guideCache[region] = (nowMs(), g)
        return .ok(g)
    }

    /// Patch the cached guide so a ★ shows instantly without a refetch.
    static func patchFav(region: String, id: String, on: Bool, channel: LiveChannel?) {
        guard var c = guideCache[region] else { return }
        var g = c.1
        g.favs.removeAll { $0 == id }
        g.favChannels.removeAll { $0.id == id }
        if on {
            g.favs.append(id)
            if let ch = channel { g.favChannels.append(ch) }
        }
        c.1 = g
        guideCache[region] = c
    }

    /// POST /live/{KEY}/fav?id=&on=&p= — params in the query string, client sends desired state.
    @MainActor
    static func setFav(_ session: Session, id: String, on: Bool) async -> Bool {
        guard let h = host(session), !key(session).isEmpty else { return false }
        let p = profile(session).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let cid = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        guard let url = URL(string: "\(h)/live/\(key(session))/fav?id=\(cid)&on=\(on ? 1 : 0)&p=\(p)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 15
        guard let res = try? await URLSession.shared.data(for: req),
              let j = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any] else { return false }
        return j["ok"] as? Bool ?? false
    }

    /// GET /live/{KEY}/games.json — cached 60s but NEVER served stale (a stale banner paints
    /// yesterday's LIVE games): past the window it refetches, and a failure yields nothing.
    @MainActor
    static func games(_ session: Session) async -> [LiveSport] {
        if let c = gamesCache, nowMs() - c.0 < 60_000 { return c.1 }
        gamesCache = nil
        guard let h = host(session), !key(session).isEmpty,
              let r = try? await API.json("/live/\(key(session))/games.json", base: h) else { return [] }
        let at = StateMerge.stamp(r["at"])
        let now = at > 0 ? at : nowMs()
        var sports = (r["sports"] as? [[String: Any]] ?? []).compactMap { LiveSport($0, now: now) }
        sports.sort { (sportsOrder.firstIndex(of: $0.sport) ?? 99) < (sportsOrder.firstIndex(of: $1.sport) ?? 99) }
        gamesCache = (nowMs(), sports)
        return sports
    }

    /// Category / search channels from the addon's tv catalog. "24/7" goes over as `24-7`.
    @MainActor
    static func catalog(_ session: Session, genre: String = "", search: String = "") async -> [Meta] {
        guard let base = session.addonBase(), let cat = session.catalogs.first(where: { $0.isLive }) else { return [] }
        var path = "/catalog/tv/\(cat.cid)"
        if !search.isEmpty {
            path += "/search=" + (search.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? search)
        } else if !genre.isEmpty {
            let g = genre == "24/7" ? "24-7" : genre
            path += "/genre=" + (g.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? g)
        }
        return Catalog.metas(try? await API.json(path + ".json", base: base), type: "tv")
    }

    /// Day tab start (ET): Today = the current half-hour; other days = 6:00 AM that day.
    static func dayStart(_ day: Int, now: Int) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = et
        let d = Date(timeIntervalSince1970: Double(now) / 1000)
        if day == 0 {
            // plain epoch floor to the half hour — date(bySetting: .second, value: 0) ROLLS
            // FORWARD to the next :00 (adds up to 59s, advancing the minute), which is why
            // every guide tick read 1:01 / 1:31 (AJ). Half-hour epoch boundaries are
            // timezone-safe for any zone on a :00/:30 offset.
            let secs = Int(d.timeIntervalSince1970)
            return (secs - secs % 1800) * 1000
        }
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: day, to: d) ?? d)
        let six = cal.date(byAdding: .hour, value: 6, to: start) ?? start
        return Int(six.timeIntervalSince1970) * 1000
    }
    static func dayLabel(_ day: Int, now: Int) -> String {
        switch day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return LiveTV.day(now + day * 86_400_000)
        }
    }
}
