import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        VStack(spacing: 24) {
            Text("Who's watching?").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 20) {
                ForEach(session.profiles) { p in
                    Button {
                        session.currentProfile = p.id
                        UserDefaults.standard.set(p.id, forKey: "curProfile")
                    } label: {
                        VStack(spacing: 8) {
                            Text(p.avatar).font(.system(size: 44))
                                .frame(width: 84, height: 84)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                            Text(p.name).font(.subheadline)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

struct SearchView: View {
    @EnvironmentObject var session: Session
    @State private var q = ""
    @State private var movies: [Meta] = []
    @State private var shows: [Meta] = []

    var body: some View {
        NavigationStack {
            Group {
                // empty query = Browse/Discover (Android's Discover surface); typing = results
                if q.trimmingCharacters(in: .whitespaces).isEmpty && movies.isEmpty && shows.isEmpty {
                    BrowseView()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if !shows.isEmpty { PosterRow(title: "Shows", metas: shows) }
                            if !movies.isEmpty { PosterRow(title: "Movies", metas: movies) }
                            if !q.isEmpty && movies.isEmpty && shows.isEmpty {
                                Text("No matches for “\(q)”.").foregroundStyle(.secondary).padding(24)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Search")
            .searchable(text: $q, prompt: "Movies, shows, people…")
            .onSubmit(of: .search) { Task { await run() } }
            .onChange(of: q) { v in if v.trimmingCharacters(in: .whitespaces).isEmpty { movies = []; shows = [] } }
        }
    }

    private func run() async {
        guard let addon = session.addons.first, q.count >= 2 else { return }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        async let m = API.json("/catalog/movie/couchking-movies/search=\(enc).json", base: addon.url)
        async let s = API.json("/catalog/series/couchking-series/search=\(enc).json", base: addon.url)
        movies = ((try? await m)?["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
        shows = ((try? await s)?["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "series") }
    }
}

struct LibraryView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let ps = session.pstate()
                    let cw = (ps["continue"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "series") }
                    let wl = (ps["watchlist"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
                    let wt = (ps["watchedTitles"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
                    if !cw.isEmpty { PosterRow(title: "Continue Watching", metas: cw) }
                    if !wl.isEmpty { PosterRow(title: "My List", metas: wl) }
                    if !wt.isEmpty { PosterRow(title: "Watched", metas: wt) }
                    if cw.isEmpty && wl.isEmpty && wt.isEmpty {
                        Text("Your list, watched titles and progress will show up here.")
                            .foregroundStyle(.secondary).padding(24)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.bg)
            .navigationTitle("Library")
        }
    }
}

struct LiveTVView: View {
    @EnvironmentObject var session: Session
    @State private var channels: [Meta] = []
    @State private var results: [Meta] = []
    @State private var catId = ""
    @State private var q = ""
    @State private var tune: Meta?
    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 12)]
    private var searching: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(searching ? results : channels) { c in
                        Button { tune = c } label: { PosterCard(meta: c) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(14)
                if searching && results.isEmpty {
                    Text("No channels or shows match.").foregroundStyle(.secondary).padding(24)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Live TV")
            .searchable(text: $q, prompt: "Channels & shows airing soon")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: q) { v in if v.trimmingCharacters(in: .whitespaces).isEmpty { results = [] } }
            .sheet(item: $tune) { c in
                StreamSheet(meta: c).presentationDetents([.medium, .large])
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let addon = session.addons.first else { return }
        guard let m = try? await API.json("/manifest.json", base: addon.url),
              let cats = m["catalogs"] as? [[String: Any]],
              let tv = cats.first(where: { $0["type"] as? String == "tv" }),
              let cid = tv["id"] as? String else { return }
        catId = cid
        if let r = try? await API.json("/catalog/tv/\(cid).json", base: addon.url) {
            channels = (r["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "tv") }
        }
    }

    // Android Live TV search: channels + shows airing in the next ~96h ("channel + when").
    private func runSearch() async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !catId.isEmpty, let addon = session.addons.first else { return }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "+", with: "%20") ?? ""
        let r = (try? await API.json("/catalog/tv/\(catId)/search=\(enc).json", base: addon.url)) ?? [:]
        if q.trimmingCharacters(in: .whitespaces) == query {   // ignore stale response
            results = (r["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "tv") }
        }
    }
}
