import Foundation

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
    @Published var state: [String: Any] = [:]   // full account blob; states[pid] = per-profile

    var signedIn: Bool { !email.isEmpty && !token.isEmpty }
    var hasAddon: Bool { !addons.isEmpty }
    var needsProfilePick: Bool { signedIn && profiles.count > 1 && currentProfile.isEmpty }

    /// "AJ #b9e1" — the per-person label every play/click carries (Android parity).
    var profileSeg: String {
        guard let p = profiles.first(where: { $0.id == currentProfile }) else { return "" }
        return "\(p.name) #\(String(p.id.suffix(4)))"
    }

    func boot() async {
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
    func signIn(email: String, password: String, create: Bool, name: String = "") async -> String? {
        do {
            var body: [String: Any] = ["email": email, "password": password]
            if create { if !name.isEmpty { body["name"] = name } } else { body["mode"] = "signin" }
            let r = try await API.postJSON("/tvapp/auth", body: body)
            guard let t = r["token"] as? String, !t.isEmpty else {
                return (r["error"] as? String) ?? "Sign-in failed"
            }
            self.email = email; self.token = t
            UserDefaults.standard.set(email, forKey: "email")
            UserDefaults.standard.set(t, forKey: "token")
            await pull()
            await checkAccess()
            return nil
        } catch { return "Can't reach the service — check the address in Settings → Addons." }
    }

    func pull() async {
        guard signedIn else { return }
        let e = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let st = try? await API.json("/tvapp/state?e=\(e)&t=\(token)") { apply(st) }
    }

    /// Store-channel flow (identical to Android store flavor): after sign-in, ask the
    /// user-entered service whether this account has an assigned addon → auto-install.
    func checkAccess() async {
        let e = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = try? await API.json("/tvapp/access?e=\(e)&t=\(token)") else { return }
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
        let body: [String: Any] = ["email": email, "token": token, "appVer": "ios-1.0.0", "state": out]
        Task { _ = try? await API.postJSON("/tvapp/state", body: body) }
    }

    private func apply(_ st: [String: Any]) {
        state = st
        profiles = (st["profiles"] as? [[String: Any]] ?? []).compactMap(Profile.init)
        if profiles.count == 1 { currentProfile = profiles[0].id }
        addons = (st["addons"] as? [[String: Any]] ?? []).compactMap {
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

    func setPstate(_ ps: [String: Any]) {
        if currentProfile.isEmpty { state.merge(ps) { _, new in new } }
        else {
            var states = state["states"] as? [String: Any] ?? [:]
            states[currentProfile] = ps
            state["states"] = states
        }
        objectWillChange.send()
        push()
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

    func detectLiveTv() async {
        for a in addons {
            if let m = try? await API.json("/manifest.json", base: a.url),
               let cats = m["catalogs"] as? [[String: Any]],
               cats.contains(where: { $0["type"] as? String == "tv" }) {
                liveTvOn = true; return
            }
        }
        liveTvOn = false
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
}

struct Addon: Identifiable {
    var id: String { url }
    let url: String, name: String
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
    func addProfile(name: String, avatar: String) {
        guard profiles.count < 5 else { return }
        let id = "p" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        var profs = state["profiles"] as? [[String: Any]] ?? []
        profs.append(["id": id, "name": name, "avatar": avatar, "color": "",
                      "mt": Int(Date().timeIntervalSince1970 * 1000)])
        state["profiles"] = profs
        var states = state["states"] as? [String: Any] ?? [:]
        states[id] = [:] as [String: Any]
        state["states"] = states
        profiles = profs.compactMap(Profile.init)
        push()
    }
    func renameProfile(_ id: String, name: String, avatar: String) {
        var profs = state["profiles"] as? [[String: Any]] ?? []
        for i in profs.indices where profs[i]["id"] as? String == id {
            profs[i]["name"] = name; profs[i]["avatar"] = avatar
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

// Skip windows + resume from the addon (same endpoint the Android player uses).
struct PlayerWindows {
    var introFrom = 0, introTo = 0, recapFrom = 0, recapTo = 0, credits = 0
    var afterCredits: [[Int]] = []
    var resumeMs = 0

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
}
