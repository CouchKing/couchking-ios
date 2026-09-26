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
        state = [:]; profiles = []; addons = []; liveTvOn = false
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
}
