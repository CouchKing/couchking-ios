import SwiftUI
import SafariServices

// Details page — Android parity: poster/meta header, trailer / library / eye (movies) /
// 👍 / 👎 action circles, cast chips, then episodes (series) or Play (movies).
struct DetailView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    @State private var full: [String: Any] = [:]
    @State private var showStreams = false
    @State private var trailerURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                actionRow
                if meta.type == "movie", session.hasAddon {
                    Button { showStreams = true } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                }
                castRow
                if meta.type == "series" {
                    EpisodesView(meta: meta, videos: full["videos"] as? [[String: Any]] ?? [])
                }
                if !session.hasAddon {
                    Text("Sign in with an enabled account to watch — tracking works for everyone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .background(Theme.bg)
        .task { await load() }
        .sheet(isPresented: $showStreams) {
            StreamSheet(meta: meta).presentationDetents([.medium, .large])
        }
        .sheet(item: $trailerURL) { url in SafariView(url: url) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterCard(meta: meta)
            VStack(alignment: .leading, spacing: 6) {
                Text(meta.name).font(.title3.bold())
                HStack(spacing: 6) {
                    if let y = full["releaseInfo"] as? String { Text(y) }
                    if let r = full["imdbRating"] as? String { Text("⭐ " + r) }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(full["description"] as? String ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(7)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            if let yt = ytId {
                ActionCircle(icon: "film", active: false, label: "Trailer") {
                    trailerURL = URL(string: "https://www.youtube.com/watch?v=\(yt)")
                }
            }
            ActionCircle(icon: "plus.circle", active: inList, label: inList ? "In Library" : "Library") { toggleList() }
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

    @ViewBuilder private var castRow: some View {
        let cast = (full["cast"] as? [String] ?? []).prefix(10)
        if !cast.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(cast), id: \.self) { nm in
                        Text(nm).font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.card, in: Capsule())
                    }
                }
            }
        }
    }

    private var ytId: String? {
        if let t = (full["trailers"] as? [[String: Any]])?.first?["source"] as? String { return t }
        return (full["trailerStreams"] as? [[String: Any]])?.first?["ytId"] as? String
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
        // addon meta first (has videos for episodes); Cinemeta as guest fallback
        if let addon = session.addons.first,
           let r = try? await API.json("/meta/\(meta.type)/\(meta.id).json", base: addon.url),
           let m = r["meta"] as? [String: Any] { full = m; return }
        if let r = try? await API.json("/meta/\(meta.type)/\(meta.id).json",
                                       base: "https://v3-cinemeta.strem.io"),
           let m = r["meta"] as? [String: Any] { full = m }
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

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

extension URL: Identifiable { public var id: String { absoluteString } }
