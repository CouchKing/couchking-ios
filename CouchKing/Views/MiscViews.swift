import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        VStack(spacing: 24) {
            BrandTitle()
            Text("Who's watching?").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 20) {
                ForEach(session.profiles) { p in
                    Button { session.switchProfile(p.id) } label: {
                        VStack(spacing: 8) {
                            ProfileAvatar(profile: p)
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

// Search (Android buildSearch): live-as-you-type with a 450ms debounce, results replace in
// place, stale responses dropped; backing out of a result restores query + results (the
// @State survives the push) with no keyboard grab. Empty query = Discover.
struct SearchView: View {
    @EnvironmentObject var session: Session
    @State private var q = ""
    @State private var movies: [Meta] = []
    @State private var shows: [Meta] = []
    @State private var people: [TMDB.Person] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if q.trimmingCharacters(in: .whitespaces).isEmpty && movies.isEmpty && shows.isEmpty && people.isEmpty {
                    BrowseView()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if !people.isEmpty { PeopleRow(people: people) }
                            if !shows.isEmpty { PosterRow(title: "Shows", metas: shows) }
                            if !movies.isEmpty { PosterRow(title: "Movies", metas: movies) }
                            if !q.isEmpty && movies.isEmpty && shows.isEmpty && people.isEmpty {
                                Text("No matches for “\(q)”.").foregroundStyle(.secondary).padding(24)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Search")
            .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
            .navigationDestination(for: TMDB.Person.self) { PersonView(person: $0) }
            .searchable(text: $q, prompt: "Movies, shows, people…")
            .onSubmit(of: .search) { searchTask?.cancel(); Task { await run(q) } }
            .onChange(of: q) { v in
                searchTask?.cancel()
                let t = v.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { movies = []; shows = []; people = []; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    await run(t)
                }
            }
        }
    }

    private func run(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return }
        let enc = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var mv: [Meta] = [], sv: [Meta] = []
        async let ppl = TMDB.people(text)   // people search rides TMDB for everyone (§1)
        if let base = session.addonBase() {
            let mc = session.catalogs.first { $0.type == "movie" && !$0.isLive }?.cid ?? "couchking-movies"
            let sc = session.catalogs.first { $0.type == "series" && !$0.isLive }?.cid ?? "couchking-series"
            async let m = API.json("/catalog/movie/\(mc)/search=\(enc).json", base: base)
            async let s = API.json("/catalog/series/\(sc)/search=\(enc).json", base: base)
            mv = Catalog.metas(try? await m, type: "movie"); sv = Catalog.metas(try? await s, type: "series")
        } else {
            // guests search Cinemeta (tracker mode)
            async let m = API.json("/catalog/movie/top/search=\(enc).json", base: Catalog.cinemeta)
            async let s = API.json("/catalog/series/top/search=\(enc).json", base: Catalog.cinemeta)
            mv = Catalog.metas(try? await m, type: "movie"); sv = Catalog.metas(try? await s, type: "series")
        }
        let pv = await ppl
        // drop a stale response after the query moved on
        guard q.trimmingCharacters(in: .whitespaces) == text else { return }
        movies = mv; shows = sv; people = Array(pv.prefix(10))
    }
}

/// Person cards strip (Android people search) → person page.
struct PeopleRow: View {
    let people: [TMDB.Person]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People").font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(people) { p in
                        NavigationLink(value: p) {
                            VStack(spacing: 4) {
                                AsyncImage(url: URL(string: p.profile ?? "")) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: { Theme.card.overlay(Image(systemName: "person.fill").foregroundStyle(.secondary)) }
                                .frame(width: 72, height: 72).clipShape(Circle())
                                Text(p.name).font(.caption2).lineLimit(1).frame(width: 84)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

// Library (Android buildLibrary): the library is the WATCHLIST ONLY ("why is stuff I clicked
// play on in my library?") — Continue Watching lives on Home, watched history is a sort here.
// All/Movies/Shows chips, sort cycle Recent / New episodes / A–Z / Z–A / Watched / Unwatched
// ("New episodes" is a real filter: only shows with unwatched new eps, most-new first), a
// search box, and "All" = Movies section first, Shows underneath, chunked rows of 15.
struct LibraryView: View {
    @EnvironmentObject var session: Session
    @State private var filter = "all"           // all | movie | series
    @State private var sort = 0
    @State private var q = ""
    @State private var newEps: [String: NewEpsInfo] = [:]
    private let sorts = ["Recent", "New episodes", "A–Z", "Z–A", "Watched", "Unwatched"]

    private var watchlist: [Meta] {
        (session.pstate()["watchlist"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
    }

    private func visible(_ type: String?) -> [Meta] {
        var list = watchlist
        if let t = type { list = list.filter { $0.type == t } }
        let text = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty { list = list.filter { $0.name.lowercased().contains(text) } }
        let added = session.pstate()["addedTs"] as? [String: Any] ?? [:]
        func stamp(_ m: Meta) -> Int { StateMerge.stamp(added["wl:" + m.id]) }
        switch sort {
        case 1:
            list = list.filter { (newEps[$0.id]?.count ?? 0) > 0 }
                .sorted { (newEps[$0.id]?.count ?? 0) > (newEps[$1.id]?.count ?? 0) }
        case 2: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case 3: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case 4: list = list.filter { session.isWatched($0.id) }
        case 5: list = list.filter { !session.isWatched($0.id) }
        default: list.sort { stamp($0) > stamp($1) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        ForEach([("all", "All"), ("movie", "Movies"), ("series", "Shows")], id: \.0) { k, label in
                            Button(label) { filter = k }
                                .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                                .background(filter == k ? Theme.accent : Theme.card, in: Capsule())
                                .foregroundStyle(filter == k ? .white : .primary)
                        }
                        Spacer()
                        Button { sort = (sort + 1) % sorts.count } label: {
                            Label(sorts[sort], systemImage: "arrow.up.arrow.down").font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.panel, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    if filter == "all" {
                        section("Movies", visible("movie"))
                        section("Shows", visible("series"))
                    } else {
                        section(filter == "movie" ? "Movies" : "Shows", visible(filter))
                    }
                    if watchlist.isEmpty {
                        Text("Titles you add to your Library show up here. Continue Watching lives on Home.")
                            .foregroundStyle(.secondary).padding(24)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.bg)
            .navigationTitle("Library")
            .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
            .searchable(text: $q, prompt: "Search your library")
            .task(id: watchlist.map(\.id).joined()) { await countNewEps() }
        }
    }

    /// Rows everywhere, no columns: chunked rows of 15 (Android buildLibrary).
    @ViewBuilder private func section(_ title: String, _ metas: [Meta]) -> some View {
        if !metas.isEmpty {
            let chunks = stride(from: 0, to: metas.count, by: 15).map { Array(metas[$0..<min($0 + 15, metas.count)]) }
            ForEach(Array(chunks.enumerated()), id: \.offset) { i, chunk in
                LibraryRow(title: i == 0 ? title : "", metas: chunk, newEps: newEps)
            }
        }
    }

    /// New-episode badges for the shows in the library (Android paintGrids(counts)).
    private func countNewEps() async {
        var out: [String: NewEpsInfo] = [:]
        for m in watchlist where m.type == "series" {
            let vids = await MetaCache.shared.videos(for: m, session: session)
            let info = session.newEpisodes(for: m, videos: vids)
            if info.count > 0 { out[m.id] = info }
        }
        newEps = out
    }
}

struct LibraryRow: View {
    let title: String
    let metas: [Meta]
    let newEps: [String: NewEpsInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.headline).padding(.horizontal, 14) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(metas) { m in
                        NavigationLink(value: m) {
                            PosterCard(meta: m, newEps: newEps[m.id]?.count ?? 0)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

// Live TV (Android buildLiveTv / liveTune): category chips from the tv catalog's manifest
// genres (Guide / sections / Local / 24-7 / All — whatever the server sends, repainted in
// place), channel rows with now-playing + LIVE badge, tap → tuning screen → stream fetch →
// HLS-vs-ckTs pick → access-gate probe → play; locked plan (`cklive:upgrade`) → 🔒 banner.
struct LiveTVView: View {
    @EnvironmentObject var session: Session
    @State private var channels: [Meta] = []
    @State private var results: [Meta] = []
    @State private var catId = ""
    @State private var genres: [String] = []
    @State private var genre = UserDefaults.standard.string(forKey: "liveGenre") ?? ""
    @State private var q = ""
    @State private var tune: Meta?
    @State private var locked = false
    @State private var loading = true
    @State private var searchTask: Task<Void, Never>?
    private var searching: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }
    var body: some View {
        NavigationStack {
            ScrollView {
                if locked {
                    VStack(spacing: 10) {
                        Text("🔒").font(.system(size: 54))
                        Text("Live TV — Locked").font(.title3.bold())
                        Text("Live TV isn't part of your plan.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    if !genres.isEmpty && !searching {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip("All Channels", "")
                                ForEach(genres, id: \.self) { g in chip(g, g) }
                            }.padding(.horizontal, 14)
                        }
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(searching ? results : channels) { c in
                            Button { tune = c } label: { LiveChannelRow(meta: c) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    if loading { ProgressView().padding(.top, 30) }
                    if searching && results.isEmpty {
                        Text("No channels or shows match.").foregroundStyle(.secondary).padding(24)
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Live TV")
            .searchable(text: $q, prompt: "Channels & shows airing soon")
            .onSubmit(of: .search) { searchTask?.cancel(); Task { await runSearch() } }
            .onChange(of: q) { v in
                searchTask?.cancel()
                if v.trimmingCharacters(in: .whitespaces).isEmpty { results = []; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    await runSearch()
                }
            }
            .fullScreenCover(item: $tune) { c in LiveTuneView(channel: c) }
            .task(id: session.catalogs.count) { await load() }
        }
    }

    private func chip(_ label: String, _ g: String) -> some View {
        Button(label) {
            genre = g; UserDefaults.standard.set(g, forKey: "liveGenre")
            Task { await loadChannels() }
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
        .background(genre == g ? Theme.accent : Theme.card, in: Capsule())
        .foregroundStyle(genre == g ? .white : .primary)
    }

    private func load() async {
        guard let tv = session.catalogs.first(where: { $0.isLive }) else { loading = false; return }
        catId = tv.cid
        genres = tv.genres
        if !genre.isEmpty && !genres.contains(genre) { genre = "" }
        await loadChannels()
    }

    private func loadChannels() async {
        guard !catId.isEmpty, let base = session.addonBase() else { return }
        loading = true
        let extra = genre.isEmpty ? "" : "/genre=" + (genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre)
        let r = (try? await API.json("/catalog/tv/\(catId)\(extra).json", base: base)) ?? [:]
        let list = Catalog.metas(r, type: "tv")
        // locked-plan state: the catalog answers with a single `cklive:upgrade` meta
        locked = list.count == 1 && list[0].id == "cklive:upgrade"
        channels = locked ? [] : list
        loading = false
    }

    // Android Live TV search: channels + shows airing in the next ~96h ("channel + when").
    private func runSearch() async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !catId.isEmpty, let base = session.addonBase() else { return }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let r = (try? await API.json("/catalog/tv/\(catId)/search=\(enc).json", base: base)) ?? [:]
        if q.trimmingCharacters(in: .whitespaces) == query {   // ignore stale response
            results = Catalog.metas(r, type: "tv")
        }
    }
}

/// Channel row (Android liveRow): logo, name, LIVE badge, now-playing program line.
struct LiveChannelRow: View {
    let meta: Meta
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: meta.poster ?? meta.logo ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
            .frame(width: 64, height: 40)
            .padding(6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meta.name).font(.subheadline.bold()).lineLimit(1)
                    Text("LIVE").font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                }
                if let d = meta.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Tuning screen (Android liveTune): logo + "Tuning ESPN… / Now: <program>" while the stream
/// list loads; then the access-gate probe + player. Back returns to the guide on this channel.
struct LiveTuneView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let channel: Meta
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    AsyncImage(url: URL(string: channel.poster ?? channel.logo ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: { Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary) }
                    .frame(height: 90).padding(.top, 20)
                    Text("Tuning \(channel.name)…").font(.headline)
                    if let d = channel.description, !d.isEmpty {
                        Text("Now: \(d)").font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    StreamList(meta: channel, autoplay: true).padding(.top, 8)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Back") { dismiss() } } }
        }
    }
}
