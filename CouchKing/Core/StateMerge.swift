import Foundation

// Union merge of account state blobs — the Swift port of Android Store.importMerge /
// blobUnion. A pull MERGES remote into local (ts-union per key, tombstone dead-checks,
// nothing ever lost) instead of replacing it, so offline changes made since the last
// push survive the next sync. Same rules the server and every other channel use:
//  - add/remove ledgers (addedTs/removedTs) union by max ts; newest action wins
//  - scoped stamps (wl:/wt:/cw:) decide their own list; bare id = legacy fallback
//  - positions "pos|dur|ts": latest stamp wins; a "pos:<key>" tombstone newer than the
//    stamp drops it (a clear on another device sticks; a re-watch stamps past it)
//  - profiles union by id, newest mt wins, profilesRemoved tombstones never resurrect
//  - ratings {v,ts}: per-id newest ts wins · newEpsSeen: highest seen-key wins
enum StateMerge {

    /// Epoch-ms out of any JSON number (Int/Double/NSNumber string-free).
    static func stamp(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    /// The ts component of a "pos|dur|ts" position string (0 when absent/malformed).
    static func posStamp(_ v: String?) -> Int {
        guard let v else { return 0 }
        let parts = v.split(separator: "|")
        guard parts.count >= 3 else { return 0 }
        return Int(parts[2]) ?? 0
    }

    /// Merge a remote account blob into the local one (v2: profiles + states[pid]).
    static func merge(local: [String: Any], remote: [String: Any]) -> [String: Any] {
        guard remote["states"] is [String: Any] else {
            // legacy blob = the active profile's content at top level
            var out = local
            for (k, v) in blobUnion(local, remote) { out[k] = v }
            if let ra = remote["addons"] as? [[String: Any]], !ra.isEmpty { out["addons"] = ra }
            return out
        }
        var out = local
        // union deletion tombstones (newest ts wins) so a profile deleted on ANY device
        // stays deleted here and can't be re-added from a stale copy
        var tomb: [String: Int] = [:]
        for src in [local["profilesRemoved"] as? [String: Any], remote["profilesRemoved"] as? [String: Any]] {
            src?.forEach { k, v in let t = stamp(v); if t > tomb[k, default: 0] { tomb[k] = t } }
        }
        out["profilesRemoved"] = tomb

        // profiles: union by id — NEWEST EDIT WINS (mt stamp), tombstoned never resurrect,
        // locally-set color survives a pre-color remote blob
        let lp = local["profiles"] as? [[String: Any]] ?? []
        let rp = remote["profiles"] as? [[String: Any]] ?? []
        let localById = Dictionary(lp.compactMap { p in (p["id"] as? String).map { ($0, p) } },
                                   uniquingKeysWith: { a, _ in a })
        var merged: [[String: Any]] = []
        for ro in rp {
            guard let id = ro["id"] as? String, !id.isEmpty, tomb[id] == nil else { continue }
            let lo = localById[id]
            if let lo, stamp(lo["mt"]) > stamp(ro["mt"]) { merged.append(lo); continue }
            var e = ro
            if (e["color"] as? String ?? "").isEmpty,
               let c = lo?["color"] as? String, !c.isEmpty { e["color"] = c }
            merged.append(e)
        }
        for lo in lp {
            guard let id = lo["id"] as? String, tomb[id] == nil,
                  !merged.contains(where: { $0["id"] as? String == id }) else { continue }
            merged.append(lo)
        }
        merged = Array(merged.prefix(5))
        if !merged.isEmpty { out["profiles"] = merged }

        // per-profile content: blobUnion local copy with the remote copy
        let ls = local["states"] as? [String: Any] ?? [:]
        let rs = remote["states"] as? [String: Any] ?? [:]
        var states: [String: Any] = [:]
        for p in merged {
            guard let id = p["id"] as? String else { continue }
            let lb = ls[id] as? [String: Any]
            let rb = rs[id] as? [String: Any]
            switch (lb, rb) {
            case let (l?, r?): states[id] = blobUnion(l, r)
            case let (l?, nil): states[id] = l
            case let (nil, r?): states[id] = r
            default: states[id] = [String: Any]()
            }
        }
        out["states"] = states

        // account-level: addons follow the account (replace when the remote has any);
        // account prefs remote-wins (per-profile prefs live inside states)
        if let ra = remote["addons"] as? [[String: Any]], !ra.isEmpty { out["addons"] = ra }
        if let rpref = remote["prefs"] as? [String: Any] { out["prefs"] = rpref }
        out["v"] = 2
        return out
    }

    /// Pure union of two profile content blobs (device A's + device B's; b = remote).
    static func blobUnion(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        // ledger union first (max ts per id) — drives the tombstone filter below
        func tsUnion(_ k: String) -> [String: Int] {
            var m: [String: Int] = [:]
            for src in [a[k] as? [String: Any], b[k] as? [String: Any]] {
                src?.forEach { id, v in let t = stamp(v); if t > m[id, default: 0] { m[id] = t } }
            }
            out[k] = m
            return m
        }
        let added = tsUnion("addedTs")
        let removed = tsUnion("removedTs")
        func dead(_ id: String) -> Bool {
            let rm = removed[id, default: 0]
            return rm > 0 && rm > added[id, default: 0]
        }
        // per-list rule (same as server): a scoped stamp alone decides its list; bare = legacy
        func deadIn(_ pre: String, _ id: String) -> Bool {
            let rs = removed[pre + id, default: 0], ads = added[pre + id, default: 0]
            if rs > 0 || ads > 0 { return rs > ads }
            return dead(id)
        }
        func unionArr(_ k: String, _ pre: String) {
            var order: [String] = []
            var byId: [String: [String: Any]] = [:]
            for src in [a[k] as? [[String: Any]], b[k] as? [[String: Any]]] {
                for e in src ?? [] {
                    guard let id = e["id"] as? String, !id.isEmpty,
                          byId[id] == nil, !deadIn(pre, id) else { continue }
                    byId[id] = e; order.append(id)
                }
            }
            out[k] = order.compactMap { byId[$0] }
        }
        unionArr("watchlist", "wl:")
        unionArr("watchedTitles", "wt:")
        unionArr("continue", "cw:")

        var ids: [String] = []
        for src in [a["watchedIds"] as? [String], b["watchedIds"] as? [String]] {
            for id in src ?? [] where !id.isEmpty && !ids.contains(id) && !deadIn("wt:", id) {
                ids.append(id)
            }
        }
        out["watchedIds"] = ids

        // positions: latest-wins per episode (both directions), and a position cleared on
        // some device carries removedTs["pos:<key>"] newer than the stamp → drop it here
        var pos: [String: String] = [:]
        for src in [a["positions"] as? [String: Any], b["positions"] as? [String: Any]] {
            src?.forEach { k, v in
                guard let s = v as? String else { return }
                if pos[k] == nil || posStamp(s) > posStamp(pos[k]) { pos[k] = s }
            }
        }
        for k in pos.keys where removed["pos:" + k, default: 0] > posStamp(pos[k]) {
            pos.removeValue(forKey: k)
        }
        out["positions"] = pos

        // cwlast resume pointer: the FRESHER episode wins per title, judged by each pointed
        // episode's own position stamp (local-always-wins kept a stale pointer forever)
        var cwlast: [String: String] = [:]
        let la = a["cwlast"] as? [String: Any] ?? [:]
        let lb = b["cwlast"] as? [String: Any] ?? [:]
        for k in Set(la.keys).union(lb.keys) {
            let ae = la[k] as? String ?? "", be = lb[k] as? String ?? ""
            let asr = ae.isEmpty ? -1 : posStamp(pos[ae])
            let bsr = be.isEmpty ? -1 : posStamp(pos[be])
            cwlast[k] = (ae.isEmpty || bsr > asr) ? be : ae
        }
        out["cwlast"] = cwlast

        // prefs: remote wins when present (the server only lets the profile's own device
        // change them, so its copy is the truth)
        if let p = (b["prefs"] as? [String: Any]) ?? (a["prefs"] as? [String: Any]) {
            out["prefs"] = p
        }
        // "+N new episodes" dismissals: HIGHEST seen-key per title wins across devices
        var neps: [String: Int] = [:]
        for src in [a["newEpsSeen"] as? [String: Any], b["newEpsSeen"] as? [String: Any]] {
            src?.forEach { k, v in let n = stamp(v); if n > neps[k, default: 0] { neps[k] = n } }
        }
        out["newEpsSeen"] = neps
        if let sh = (b["shelves"] as? [String]) ?? (a["shelves"] as? [String]) { out["shelves"] = sh }

        // thumbs ratings {v,ts}: per-id newest ts wins (remote wins ties — server rule)
        var ratings: [String: Any] = [:]
        for src in [a["ratings"] as? [String: Any], b["ratings"] as? [String: Any]] {
            src?.forEach { k, v in
                guard let e = v as? [String: Any] else { return }
                if let cur = ratings[k] as? [String: Any], stamp(cur["ts"]) > stamp(e["ts"]) { return }
                ratings[k] = e
            }
        }
        out["ratings"] = ratings

        // anything neither side types (future keys) rides along, remote copy preferred
        for src in [b, a] {
            for (k, v) in src where out[k] == nil { out[k] = v }
        }
        return out
    }
}
