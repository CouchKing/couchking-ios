import SwiftUI

// Details page — Android parity: trailer / library / eye (movies) / 👍 / 👎,
// then episodes (series) or streams (movies, addon users only).
struct DetailView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    @State private var full: [String: Any] = [:]
    @State private var streams: [[String: Any]] = []
    @State private var playURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    PosterCard(meta: meta)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meta.name).font(.title3.bold())
                        Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
                actionRow
                if session.hasAddon {
                    StreamList(meta: meta, streams: streams, playURL: $playURL)
                } else {
                    WhereToWatch(meta: meta)   // tracker mode: providers, not streams
                }
            }
            .padding(14)
        }
        .background(Theme.bg)
        .task { await load() }
        .fullScreenCover(item: $playURL) { url in PlayerView(url: url, meta: meta) }
    }

    private var desc: String {
        (full["description"] as? String) ?? ""
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            ActionCircle(icon: "plus", active: inList, label: "Library") { toggleList() }
            if meta.type == "movie" {
                ActionCircle(icon: "eye", active: isWatched, label: "Watched") { toggleWatched() }
            }
            ActionCircle(icon: "hand.thumbsup", active: session.rating(meta.id) == 1, label: "Like") {
                session.setRating(meta.id, 1)
            }
            ActionCircle(icon: "hand.thumbsdown", active: session.rating(meta.id) == -1, label: "Not for me") {
                session.setRating(meta.id, -1)
            }
            Spacer()
        }
    }

    private var inList: Bool {
        ((session.pstate()["watchlist"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == meta.id }
    }
    private var isWatched: Bool {
        ((session.pstate()["watchedIds"] as? [String]) ?? []).contains(meta.id)
    }

    private func stampKey(_ ps: inout [String: Any], _ ledger: String, _ key: String) {
        var m = ps[ledger] as? [String: Any] ?? [:]
        m[key] = Int(Date().timeIntervalSince1970 * 1000)
        ps[ledger] = m
    }

    private func toggleList() {
        var ps = session.pstate()
        var wl = ps["watchlist"] as? [[String: Any]] ?? []
        if inList { wl.removeAll { $0["id"] as? String == meta.id }; stampKey(&ps, "removedTs", "wl:" + meta.id) }
        else {
            wl.insert(["id": meta.id, "type": meta.type, "name": meta.name, "poster": meta.poster ?? ""], at: 0)
            stampKey(&ps, "addedTs", "wl:" + meta.id)
        }
        ps["watchlist"] = wl
        session.setPstate(ps)
    }

    private func toggleWatched() {
        var ps = session.pstate()
        var ids = ps["watchedIds"] as? [String] ?? []
        var wt = ps["watchedTitles"] as? [[String: Any]] ?? []
        if isWatched {
            ids.removeAll { $0 == meta.id }; wt.removeAll { $0["id"] as? String == meta.id }
            stampKey(&ps, "removedTs", "wt:" + meta.id)
        } else {
            ids.append(meta.id)
            wt.insert(["id": meta.id, "type": meta.type, "name": meta.name, "poster": meta.poster ?? ""], at: 0)
            stampKey(&ps, "addedTs", "wt:" + meta.id)
        }
        ps["watchedIds"] = ids; ps["watchedTitles"] = wt
        session.setPstate(ps)
    }

    private func load() async {
        guard let addon = session.addons.first else { return }
        if let r = try? await API.json("/meta/\(meta.type)/\(meta.id).json", base: addon.url),
           let m = r["meta"] as? [String: Any] { full = m }
        if meta.type == "movie" {
            let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let r = try? await API.json("/stream/movie/\(meta.id).json?u=\(u)", base: addon.url) {
                streams = r["streams"] as? [[String: Any]] ?? []
            }
        }
    }
}

struct ActionCircle: View {
    let icon: String, active: Bool, label: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: active ? icon + ".fill" : icon)
                    .frame(width: 46, height: 46)
                    .background(Theme.card, in: Circle())
                    .foregroundStyle(active ? Theme.accent : .primary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct StreamList: View {
    let meta: Meta
    let streams: [[String: Any]]
    @Binding var playURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !streams.isEmpty { Text("Streams").font(.headline) }
            ForEach(Array(streams.prefix(8).enumerated()), id: \.offset) { _, s in
                Button {
                    if let u = s["url"] as? String, let url = URL(string: u) { playURL = url }
                } label: {
                    VStack(alignment: .leading) {
                        Text(s["name"] as? String ?? "Stream").font(.subheadline.bold())
                        Text((s["title"] as? String ?? s["description"] as? String ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct WhereToWatch: View {
    let meta: Meta
    var body: some View {
        // Tracker mode: TMDB watch-providers (labels only — the Amazon deep-link lesson).
        Text("Where to watch appears here for guests.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }
