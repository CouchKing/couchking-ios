import Foundation
import SwiftUI

// Account + profile session, mirroring Android's Store.kt semantics:
// - per-profile content state (watchlist/watched/continue/positions/ratings/prefs)
// - state sync via POST /tvapp/state (server merges: tombstones, newest-ts ratings)
// - profiles carry "#tag" (id last-4) so the server attributes plays per person
@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published var email: String = UserDefaults.standard.string(forKey: "email") ?? ""
    @Published var token: String = UserDefaults.standard.string(forKey: "token") ?? ""
    @Published var profiles: [Profile] = []
    @Published var currentProfile: String = UserDefaults.standard.string(forKey: "curProfile") ?? ""
    @Published var addons: [Addon] = []
    @Published var liveTvOn = false
    @Published var catalogs: [AddonCatalog] = []   // the addon manifest's catalog list
    /// Bumped by the player on exit (Android `homeStale`) so Home re-pulls + repaints CW.
    @Published var homeStale = 0
    /// Mandatory store update gate (Android showStoreMandatoryUpdate): set → blocking screen.
    @Published var updateRequired: StoreVersion?
    @Published var state: [String: Any] = [:]   // full account blob; states[pid] = per-profile
    // cached access status (Android Store.accessExpiry/accessDaysLeft): drives the Settings
    // account card + the play-time expiry banner. Browsing never blocks on it.
    @Published var accessExpiry: String = UserDefaults.standard.string(forKey: "accessExpiry") ?? ""
    @Published var accessDaysLeft: Int = UserDefaults.standard.object(forKey: "accessDaysLeft") as? Int ?? -1

    static let appVer = "ios-" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")

    var signedIn: Bool { !email.isEmpty && !token.isEmpty }
    var hasAddon: Bool { !addons.isEmpty }
    var needsProfilePick: Bool { signedIn && profiles.count > 1 && currentProfile.isEmpty }

    /// Which account the on-device library belongs to. Survives sign-out (unlike email/token)
    /// so a later sign-in by a DIFFERENT email still knows the local state isn't theirs.
    var contentOwner: String {
        get { UserDefaults.standard.string(forKey: "contentOwner") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "contentOwner") }
    }

    /// ≤0 days with a real expiry date = expired/revoked (Android isExpired). Browse stays
    /// open — only the stream list shows the banner, at play time.
    var isExpired: Bool {
        signedIn && !accessExpiry.isEmpty && accessDaysLeft <= 0 && accessDaysLeft > -3650
    }

    /// "AJ #b9e1" — the per-person label every play/click carries (Android parity).
    var profileSeg: String {
        guard let p = profiles.first(where: { $0.id == currentProfile }) else { return "" }
        return "\(p.name) #\(String(p.id.suffix(4)))"
    }

    func boot() async {
        await checkStoreVersion()
        guard signedIn else { return }
        await pull()
        await detectLiveTv()
        // 60s live pull, same cadence as Android
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                await self?.pull()
            }
        }
    }

    /// Same contract as Android: POST /tvapp/auth {email,password,mode,name}.
    /// NOTHING commits until the credentials are accepted (Android Sync.auth order) — a
    /// typo'd or abandoned sign-in must never wipe the real owner's library or leave the
    /// device half signed-in as a garbage account.
    func signIn(email: String, password: String, create: Bool, name: String = "") async -> String? {
        do {
            var body: [String: Any] = ["email": email, "password": password, "appVer": Self.appVer]
            if create { if !name.isEmpty { body["name"] = name } } else { body["mode"] = "signin" }
            let r = try await API.postJSON("/tvapp/auth", body: body)
            guard let t = r["token"] as? String, !t.isEmpty else {
                return (r["error"] as? String) ?? "Sign-in failed"
            }
            // verified — NOW commit. A DIFFERENT account than the one this device's library
            // belongs to: start clean (content-owner guard, Store.contentOwner parity).
            if !contentOwner.isEmpty && contentOwner.lowercased() != email.lowercased() {
                clearContentState()
            }
            contentOwner = email
            self.email = email
            UserDefaults.standard.set(email, forKey: "email")
            // same email returning after sign-out: everything comes back from the on-device
            // stash BEFORE any network — profiles, addons, every profile's library/continue
            unstashAccount(email)
            self.token = t
            UserDefaults.standard.set(t, forKey: "token")
            await pull()
            await checkAccess()
            await detectLiveTv()
            return nil
        } catch { return "Can't reach the service — check the address in Settings → Addons." }
    }

    /// Android sign-out semantics: park the WHOLE account state under its email (device-local
    /// safety net so re-sign-in restores instantly, even offline), then a guest starts CLEAN —
    /// addons, library, Live TV all leave with the account. The serviceBase deliberately
    /// SURVIVES: it's where accounts live, not account content.
    func signOut() {
        stashAccount()
        email = ""; token = ""
        UserDefaults.standard.removeObject(forKey: "email")
        UserDefaults.standard.removeObject(forKey: "token")
        clearContentState()
        setAccessStatus(expires: "", daysLeft: -1)
    }

    /// Wipe everything an ACCOUNT owns from memory + device: library, profiles, addons,
    /// Live TV. Without this, sign-in merged the device's existing library into the new
    /// account and pushed it up — every email used on the device "shared" one library.
    func clearContentState() {
        state = [:]; profiles = []; addons = []; liveTvOn = false; catalogs = []
        currentProfile = ""
        UserDefaults.standard.set("", forKey: "curProfile")
    }

    private func stashKey(_ e: String) -> String {
        "acctstash:" + e.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func stashAccount() {
        guard !email.isEmpty, !state.isEmpty,
              JSONSerialization.isValidJSONObject(state),
              let d = try? JSONSerialization.data(withJSONObject: state) else { return }
        UserDefaults.standard.set(d, forKey: stashKey(email))
    }

    @discardableResult
    func unstashAccount(_ email: String) -> Bool {
        let k = stashKey(email)
        guard let d = UserDefaults.standard.data(forKey: k),
              let st = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        apply(st)   // local state is empty right after sign-out/owner-wipe, so apply = restore
        UserDefaults.standard.removeObject(forKey: k)
        return true
    }

    func dropStash(_ email: String) { UserDefaults.standard.removeObject(forKey: stashKey(email)) }

    /// Permanently delete the account server-side (App Store requires this for apps with
    /// account creation), then forget it locally. Returns false when unreachable/refused.
    func deleteAccount() async -> Bool {
        guard signedIn else { return false }
        guard let r = try? await API.postJSON("/tvapp/delete", body: ["email": email, "token": token]),
              r["ok"] as? Bool == true else { return false }
        dropStash(email)
        email = ""; token = ""
        UserDefaults.standard.removeObject(forKey: "email")
        UserDefaults.standard.removeObject(forKey: "token")
        contentOwner = ""
        clearContentState()
        setAccessStatus(expires: "", daysLeft: -1)
        return true
    }

    func setAccessStatus(expires: String, daysLeft: Int) {
        accessExpiry = expires; accessDaysLeft = daysLeft
        UserDefaults.standard.set(expires, forKey: "accessExpiry")
        UserDefaults.standard.set(daysLeft, forKey: "accessDaysLeft")
    }

    /// Every foreground (Android onResume parity): pull cross-device state, refresh the
    /// cached expiry, pick up an addon assigned AFTER sign-in without visiting Settings,
    /// and re-detect Live TV so the tab appears/disappears live.
    func foregroundResume() async {
        await checkStoreVersion()   // re-check on every foreground; clears a stale gate once updated
        guard signedIn else { return }
        await pull()
        await checkAccess()
        await detectLiveTv()
    }

    func pull() async {
        guard signedIn else { return }
        // upgrade migration: devices from before contentOwner existed — the signed-in
        // account claims the local library so a future different-email sign-in wipes it
        if contentOwner.isEmpty { contentOwner = email }
        let e = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let st = try? await API.json("/tvapp/state?e=\(e)&t=\(token)") {
            apply(st)
            push()   // push the union straight back (Android Sync.pullMerge: merge, then push)
        }
    }

    /// Store-channel flow (identical to Android store flavor): after sign-in, ask the
    /// user-entered service whether this account has an assigned addon → auto-install.
    /// Also caches expires/daysLeft for the Settings card + play-time expiry banner.
    func checkAccess() async {
        guard signedIn else { return }
        let e = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let k = subKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = try? await API.json("/tvapp/access?e=\(e)&t=\(token)&k=\(k)") else { return }
        setAccessStatus(expires: r["expires"] as? String ?? "",
                        daysLeft: r["daysLeft"] as? Int ?? -1)
        if let allowed = r["allowed"] as? Bool, allowed,
           let addonUrl = r["addon"] as? String, !addonUrl.isEmpty,
           !addons.contains(where: { $0.url == addonUrl }) {
            addons.append(Addon(url: addonUrl, name: "CouchKing"))
            var st = state
            st["addons"] = addons.map { ["url": $0.url, "name": $0.name] }
            state = st
            push()
            await detectLiveTv()
        }
    }

    func push() {
        guard signedIn else { return }
        var out = state
        out["v"] = 2
        out["activeProfile"] = currentProfile   // per-profile settings guard (server 2.0.93+)
        let body: [String: Any] = ["email": email, "token": token, "appVer": Self.appVer, "state": out]
        Task { _ = try? await API.postJSON("/tvapp/state", body: body) }
    }

    /// Merge a remote/stashed blob into local state (union — nothing ever lost; offline
    /// changes since the last push survive) and re-derive profiles/addons from the result.
    private func apply(_ st: [String: Any]) {
        state = StateMerge.merge(local: state, remote: st)
        profiles = (state["profiles"] as? [[String: Any]] ?? []).compactMap(Profile.init)
        if profiles.count == 1 { currentProfile = profiles[0].id }
        addons = (state["addons"] as? [[String: Any]] ?? []).compactMap {
            guard let u = $0["url"] as? String else { return nil }
            return Addon(url: u, name: $0["name"] as? String ?? "Addon")
        }
        objectWillChange.send()
    }

    /// The ACTIVE profile's content blob (ratings, lists, prefs live here).
    func pstate() -> [String: Any] {
        guard !currentProfile.isEmpty,
              let states = state["states"] as? [String: Any],
              let ps = states[currentProfile] as? [String: Any] else { return state }
        return ps
    }

    /// `push: false` = local-only save (the player's 30s resume beat; the account blob
    /// rides up on its own 90s cadence instead of every save).
    func setPstate(_ ps: [String: Any], push doPush: Bool = true) {
        if currentProfile.isEmpty { state.merge(ps) { _, new in new } }
        else {
            var states = state["states"] as? [String: Any] ?? [:]
            states[currentProfile] = ps
            state["states"] = states
        }
        objectWillChange.send()
        if doPush { push() }
    }

    // ---- thumbs (identical semantics to Android/web: {v: 1|-1|0, ts}) ----
    func rating(_ id: String) -> Int {
        ((pstate()["ratings"] as? [String: Any])?[id] as? [String: Any])?["v"] as? Int ?? 0
    }
    func setRating(_ id: String, _ v: Int) {
        var ps = pstate()
        var ratings = ps["ratings"] as? [String: Any] ?? [:]
        let cur = (ratings[id] as? [String: Any])?["v"] as? Int ?? 0
        ratings[id] = ["v": cur == v ? 0 : v, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        ps["ratings"] = ratings
        setPstate(ps)
    }

    /// One tiny POST per beat/sit-down (Android Ck.reportServer): powers For You's
    /// completion signal, cross-device resume, and the learned credits timing.
    func reportProgress(id: String, season: Int?, episode: Int?, pos: Int, dur: Int) {
        let k = subKey
        guard !k.isEmpty, dur > 0, pos >= 5000 else { return }
        let body: [String: Any] = ["k": k, "u": profileSeg, "i": id,
                                   "s": season.map(String.init) ?? "",
                                   "e": episode.map(String.init) ?? "",
                                   "pos": pos, "dur": dur]
        Task { _ = try? await API.postJSON("/player/progress", body: body) }
    }

    /// Wipe the server's resume for a title (Android Ck.clearServer) — without it the
    /// other device re-fetches ckpos and a finished/cleared title comes right back.
    func clearServerResume(id: String) {
        let k = subKey
        guard !k.isEmpty else { return }
        let body: [String: Any] = ["k": k, "u": profileSeg, "i": id]
        Task { _ = try? await API.postJSON("/player/clear", body: body) }
    }

    /// Re-read the addon manifest (every resume / sign-out / addon change): caches the catalog
    /// list the Home lineup + Discover + shelves picker are built from, and flips the Live TV
    /// tab on/off live when a `tv` catalog appears/disappears (Android detectLiveTv).
    func detectLiveTv() async {
        var found: [AddonCatalog] = []
        for a in addons {
            if let m = try? await API.json("/manifest.json", base: a.url),
               let cats = m["catalogs"] as? [[String: Any]] {
                found += cats.compactMap(AddonCatalog.init)
            }
        }
        catalogs = found
        liveTvOn = found.contains { $0.isLive }
    }

    /// Switch the active person: per-profile content leaves memory immediately (rows,
    /// CW, prefs all re-derive from the new pstate) and Home repaints (Android switchProfile /
    /// clearProfileContent). Empty id = back to the "Who's watching?" gate.
    func switchProfile(_ id: String) {
        currentProfile = id
        UserDefaults.standard.set(id, forKey: "curProfile")
        homeStale += 1
        objectWillChange.send()
    }

    /// Android `Addons.withUser`: the addon URL's config segment is URL-encoded JSON
    /// ({"subKey":…,"userName":…}); swap THIS profile's "Name #tag" into userName so every
    /// catalog/stream/For You call attributes to the person. Falls back to the raw URL
    /// when the addon has no config segment.
    func addonBase() -> String? {
        guard let a = addons.first else { return nil }
        return Session.withUser(a.url, profileSeg)
    }

    static func withUser(_ url: String, _ user: String) -> String {
        guard !user.isEmpty, var comps = URLComponents(string: url) else { return url }
        var parts = comps.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices {
            guard let dec = parts[i].removingPercentEncoding, dec.hasPrefix("{"),
                  let d = dec.data(using: .utf8),
                  var cfg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            cfg["userName"] = user
            guard let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.withoutEscapingSlashes]),
                  let js = String(data: out, encoding: .utf8) else { continue }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/:{}\"")
            for j in parts.indices where j != i {   // every segment must be percent-encoded
                parts[j] = parts[j].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parts[j]
            }
            parts[i] = js.addingPercentEncoding(withAllowedCharacters: allowed) ?? parts[i]
            comps.percentEncodedPath = parts.joined(separator: "/")
            return comps.string ?? url
        }
        return url
    }

    // ---- customizable shelves (Android Store.enabledShelves / persistShelves) ----
    /// Shelf keys ("type/id") the person enabled, in their order; nil = never customized.
    func shelfKeys() -> [String]? { pstate()["shelves"] as? [String] }

    /// The Home shelf lineup: the saved order (dropping catalogs the manifest no longer has),
    /// or every browsable catalog in manifest order when never customized.
    func enabledShelves() -> [AddonCatalog] {
        let all = catalogs.filter { $0.isShelf }
        guard let keys = shelfKeys() else { return all }
        return keys.compactMap { k in all.first { $0.id == k } }
    }

    private static var shelfPushTask: Task<Void, Never>?
    /// Save the lineup (order = user order). Debounced push so the 60s pull can't revert a
    /// half-finished reorder (Android persistShelves).
    func setShelves(_ keys: [String]) {
        var ps = pstate()
        ps["shelves"] = keys
        setPstate(ps, push: false)
        Session.shelfPushTask?.cancel()
        Session.shelfPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    // ---- store mandatory-update gate (Android showStoreMandatoryUpdate + Updater.newer) ----
    /// GET <serviceBase>/tvapp/store-version → {minVersion, latest, url}. Below minVersion =
    /// blocking screen with one button to the App Store listing. Rides the user-entered
    /// service base (nothing baked); a cleared gate stays cleared once the app is current.
    func checkStoreVersion() async {
        guard !API.serviceBase.isEmpty else { return }
        guard let r = try? await API.json("/tvapp/store-version?platform=ios&v=\(Self.appVer)") else { return }
        let minV = (r["minVersion"] as? String) ?? (r["minVersionIos"] as? String) ?? ""
        let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        if !minV.isEmpty, StoreVersion.newer(minV, than: cur) {
            updateRequired = StoreVersion(minVersion: minV,
                                          latest: r["latest"] as? String ?? minV,
                                          url: (r["iosUrl"] as? String) ?? (r["url"] as? String) ?? "")
        } else {
            updateRequired = nil
        }
    }
}

struct Profile: Identifiable {
    let id: String, name: String, avatar: String, color: String
    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = o["name"] as? String ?? "Profile"
        avatar = o["avatar"] as? String ?? "🍿"
        color = o["color"] as? String ?? ""
    }
    /// Android addAvatarColorPicker palette — the hue drives the avatar tile everywhere.
    static let colors = ["#7B5BF5", "#E6467A", "#F28C28", "#2BB673", "#2F9BE8", "#F2C94C",
                         "#9B59B6", "#1ABC9C", "#E74C3C", "#95A5A6"]
    static func tint(_ hex: String) -> Color {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return Theme.card }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

struct Addon: Identifiable {
    var id: String { url }
    let url: String, name: String
}

struct StoreVersion {
    let minVersion: String, latest: String, url: String
    /// Numeric segment compare (Android Updater.newer): "1.2.10" > "1.2.9"; missing = 0.
    static func newer(_ a: String, than b: String) -> Bool {
        func segs(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber && $0 != "." }).first
                .map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = segs(a), y = segs(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// ---- parity extensions (settings sync, profiles CRUD, player context) ----
extension Session {
    /// subKey + userName parsed from the installed addon's config URL (Android parity:
    /// the addon path carries {"subKey":..,"userName":..} URL-encoded).
    var subKey: String {
        guard let a = addons.first,
              let comp = a.url.removingPercentEncoding,
              let m = comp.range(of: #""subKey"\s*:\s*"([^"]+)""#, options: .regularExpression)
        else { return "" }
        let s = String(comp[m])
        return s.replacingOccurrences(of: #""subKey""#, with: "")
            .replacingOccurrences(of: #"[":\s]"#, with: "", options: .regularExpression)
    }

    // Per-person prefs live in the profile state (2.0.93 semantics) — these helpers keep
    // a local mirror for instant UI and push the profile copy for cross-device sync.
    func pref<T>(_ key: String, _ def: T) -> T {
        ((pstate()["prefs"] as? [String: Any])?[key] as? T) ?? def
    }
    func setPref(_ key: String, _ value: Any) {
        var ps = pstate()
        var prefs = ps["prefs"] as? [String: Any] ?? [:]
        prefs[key] = value
        ps["prefs"] = prefs
        setPstate(ps)
    }

    // ---- profiles CRUD (Android parity: max 5, tombstoned deletes) ----
    func addProfile(name: String, avatar: String, color: String = "") {
        guard profiles.count < 5 else { return }
        let id = "p" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        var profs = state["profiles"] as? [[String: Any]] ?? []
        profs.append(["id": id, "name": name, "avatar": avatar, "color": color,
                      "mt": Int(Date().timeIntervalSince1970 * 1000)])
        state["profiles"] = profs
        var states = state["states"] as? [String: Any] ?? [:]
        states[id] = [:] as [String: Any]
        state["states"] = states
        profiles = profs.compactMap(Profile.init)
        push()
    }
    func renameProfile(_ id: String, name: String, avatar: String, color: String? = nil) {
        var profs = state["profiles"] as? [[String: Any]] ?? []
        for i in profs.indices where profs[i]["id"] as? String == id {
            profs[i]["name"] = name; profs[i]["avatar"] = avatar
            if let color { profs[i]["color"] = color }
            profs[i]["mt"] = Int(Date().timeIntervalSince1970 * 1000)
        }
        state["profiles"] = profs
        profiles = profs.compactMap(Profile.init)
        push()
    }
    func deleteProfile(_ id: String) {
        var profs = state["profiles"] as? [[String: Any]] ?? []
        profs.removeAll { $0["id"] as? String == id }
        state["profiles"] = profs
        var tomb = state["profilesRemoved"] as? [String: Any] ?? [:]
        tomb[id] = Int(Date().timeIntervalSince1970 * 1000)
        state["profilesRemoved"] = tomb
        var states = state["states"] as? [String: Any] ?? [:]
        states.removeValue(forKey: id)
        state["states"] = states
        profiles = profs.compactMap(Profile.init)
        if currentProfile == id { currentProfile = "" ; UserDefaults.standard.set("", forKey: "curProfile") }
        push()
    }
    func removeAddon(_ url: String) {
        addons.removeAll { $0.url == url }
        state["addons"] = addons.map { ["url": $0.url, "name": $0.name] }
        liveTvOn = false
        push()
        Task { await detectLiveTv() }
    }
}

// A Continue Watching tile: the title, how far through it is (0…1) for the progress bar, the
// episode the tap resumes (cwlast), its activity stamp (cwOrder) and the +N new-episodes badge.
struct CWItem: Identifiable {
    let meta: Meta
    let progress: Double
    var resumeKey: String = ""     // "tt1:2:5" for a show, the id for a movie
    var order: Int = 0             // Android cwOrder: watch stamp, floated by a new ep's air time
    var newEps: Int = 0
    var latestAir: Int = 0
    var id: String { meta.id }
}

extension Session {
    /// The active profile's Continue Watching list (Android Home CW row): entries the player
    /// stamped, newest first, each with its resume % from `positions`. Fully-finished titles the
    /// player cleared won't have a live position, so they fall to 0 and can be filtered by the UI.
    func continueWatching() -> [CWItem] {
        let ps = pstate()
        let cw = ps["continue"] as? [[String: Any]] ?? []
        let positions = ps["positions"] as? [String: Any] ?? [:]
        let cwlast = ps["cwlast"] as? [String: Any] ?? [:]
        let watchedIds = Set(ps["watchedIds"] as? [String] ?? [])
        var out: [CWItem] = []
        for e in cw {
            guard let id = e["id"] as? String,
                  let meta = Meta(e, type: e["type"] as? String ?? "movie") else { continue }
            // series resume-target is the last-watched episode's posKey; movies key on the id
            let key = (cwlast[id] as? String) ?? id
            var prog = 0.0
            var stamp = StateMerge.stamp(e["ts"])
            if let s = positions[key] as? String {
                let p = s.split(separator: "|")
                if p.count >= 2, let pos = Double(p[0]), let dur = Double(p[1]), dur > 0 {
                    prog = min(1.0, pos / dur)
                }
                stamp = max(stamp, StateMerge.posStamp(s))
            }
            // drop a movie that's marked fully watched (a finished show stays — next episode)
            if meta.type == "movie" && watchedIds.contains(id) { continue }
            out.append(CWItem(meta: meta, progress: prog, resumeKey: key, order: stamp))
        }
        return out.sorted { $0.order > $1.order }
    }
}

// ---- library / watched / progress mutations (Android titleMenu + scoped tombstones) ----
// Every list carries an addedTs/removedTs ledger keyed wl:/wt:/cw: so the server merge keeps
// adds and removes straight across devices (Android Store scoped-tombstones, Sep 17).
extension Session {
    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func inLibrary(_ id: String) -> Bool {
        (pstate()["watchlist"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id }
    }
    func isWatched(_ id: String) -> Bool {
        (pstate()["watchedIds"] as? [String] ?? []).contains(id)
    }

    func toggleLibrary(_ meta: Meta) {
        var ps = pstate()
        var wl = ps["watchlist"] as? [[String: Any]] ?? []
        var added = ps["addedTs"] as? [String: Any] ?? [:]
        var removed = ps["removedTs"] as? [String: Any] ?? [:]
        let now = nowMs()
        if let i = wl.firstIndex(where: { $0["id"] as? String == meta.id }) {
            wl.remove(at: i); removed["wl:" + meta.id] = now; added["wl:" + meta.id] = nil
        } else {
            wl.insert(meta.dict, at: 0); added["wl:" + meta.id] = now; removed["wl:" + meta.id] = nil
        }
        ps["watchlist"] = wl; ps["addedTs"] = added; ps["removedTs"] = removed
        setPstate(ps)
    }

    func toggleWatched(_ meta: Meta) {
        var ps = pstate()
        var ids = ps["watchedIds"] as? [String] ?? []      // server merges this as a set union
        var wt = ps["watchedTitles"] as? [[String: Any]] ?? []
        var added = ps["addedTs"] as? [String: Any] ?? [:]
        var removed = ps["removedTs"] as? [String: Any] ?? [:]
        let now = nowMs()
        if ids.contains(meta.id) {
            ids.removeAll { $0 == meta.id }; wt.removeAll { $0["id"] as? String == meta.id }
            removed["wt:" + meta.id] = now; added["wt:" + meta.id] = nil
        } else {
            ids.append(meta.id)
            if !wt.contains(where: { $0["id"] as? String == meta.id }) { wt.insert(meta.dict, at: 0) }
            added["wt:" + meta.id] = now; removed["wt:" + meta.id] = nil
            // finished → leaves Continue Watching
            var cw = ps["continue"] as? [[String: Any]] ?? []
            cw.removeAll { $0["id"] as? String == meta.id }
            ps["continue"] = cw
        }
        ps["watchedIds"] = ids; ps["watchedTitles"] = wt
        ps["addedTs"] = added; ps["removedTs"] = removed
        setPstate(ps)
    }

    /// Clear progress = drop from Continue Watching + wipe resume positions (Android "Clear
    /// Progress" single option leaves CW) and tell the server so it can't re-hydrate.
    func clearProgress(_ meta: Meta) {
        var ps = pstate()
        var cw = ps["continue"] as? [[String: Any]] ?? []
        cw.removeAll { $0["id"] as? String == meta.id }
        ps["continue"] = cw
        var positions = ps["positions"] as? [String: Any] ?? [:]
        positions = positions.filter { !($0.key == meta.id || $0.key.hasPrefix(meta.id + ":")) }
        ps["positions"] = positions
        var cwlast = ps["cwlast"] as? [String: Any] ?? [:]
        cwlast[meta.id] = nil; ps["cwlast"] = cwlast
        var removed = ps["removedTs"] as? [String: Any] ?? [:]
        removed["cw:" + meta.id] = nowMs(); ps["removedTs"] = removed
        setPstate(ps)
        clearServerResume(id: meta.id)
    }
}

// Skip windows + resume from the addon (same endpoint the Android player uses).
struct PlayerWindows {
    var introFrom = 0, introTo = 0, recapFrom = 0, recapTo = 0, credits = 0
    var afterCredits: [[Int]] = []
    var resumeMs = 0

    @MainActor
    static func fetch(session: Session, id: String, season: Int?, episode: Int?) async -> PlayerWindows {
        var w = PlayerWindows()
        let k = session.subKey
        guard !k.isEmpty else { return w }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var path = "/player/resume?k=\(k)&u=\(u)&i=\(id)"
        if let s = season, let e = episode { path += "&s=\(s)&e=\(e)" }
        guard let r = try? await API.json(path) else { return w }
        w.introFrom = r["introFrom"] as? Int ?? 0
        w.introTo = r["introTo"] as? Int ?? 0
        w.recapFrom = r["recapFrom"] as? Int ?? 0
        w.recapTo = r["recapTo"] as? Int ?? 0
        w.credits = r["credits"] as? Int ?? 0
        w.afterCredits = r["afterCredits"] as? [[Int]] ?? []
        w.resumeMs = r["pos"] as? Int ?? 0
        return w
    }

    /// Chapter windows riding on a stream object (Android `windows` intent extra): either a
    /// nested `windows` dict or the same keys flat on the stream.
    init(stream s: [String: Any]) {
        let w = (s["windows"] as? [String: Any]) ?? s
        func i(_ k: String) -> Int {
            if let v = w[k] as? Int { return v }
            if let v = w[k] as? Double { return Int(v) }
            return 0
        }
        introFrom = i("introFrom"); introTo = i("introTo")
        recapFrom = i("recapFrom"); recapTo = i("recapTo")
        credits = i("credits")
        afterCredits = w["afterCredits"] as? [[Int]] ?? []
    }
    init() {}

    var hasWindows: Bool { introTo > 0 || recapTo > 0 || credits > 0 || !afterCredits.isEmpty }

    /// Take the stream's windows over the server's, keeping the server's resume position.
    mutating func adopt(_ o: PlayerWindows) {
        if o.introTo > 0 { introFrom = o.introFrom; introTo = o.introTo }
        if o.recapTo > 0 { recapFrom = o.recapFrom; recapTo = o.recapTo }
        if o.credits > 0 { credits = o.credits }
        if !o.afterCredits.isEmpty { afterCredits = o.afterCredits }
    }
}
