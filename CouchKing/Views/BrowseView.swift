import SwiftUI

// Discover (Android buildDiscover): Movies / Shows / Anime, a catalog dropdown (Discovery
// MOVIE_CATS / TV_CATS — Popular · Trending · For You · New · Top Rated · New in Theaters …
// providers), a genre dropdown (accurate TMDB ids), a year dropdown (TMDB discover reroute),
// and the results as ROWS of 15 — "rows, like everywhere else (AJ: grids are stupid)" — so
// nothing ever overflows a phone width. More rows load as you reach the last one.
struct DiscoverCat: Hashable {
    let label: String
    var cine: String = ""          // Cinemeta catalog id
    var tmdb: String? = nil        // TMDB path + params
    var forYou = false
}

enum DiscoverCats {
    private static func prov(_ kind: String, _ ids: String) -> String {
        "discover/\(kind)?with_watch_providers=\(ids)&watch_region=US&sort_by=popularity.desc"
    }
    static let movie: [DiscoverCat] = [
        DiscoverCat(label: "Popular", cine: "top"),
        DiscoverCat(label: "Trending", tmdb: "trending/movie/week"),
        DiscoverCat(label: "For You", forYou: true),
        DiscoverCat(label: "New", cine: "year"),
        DiscoverCat(label: "Top Rated", cine: "imdbRating"),
        DiscoverCat(label: "New in Theaters", tmdb: ShelfCatalog.nowPlaying()),
        DiscoverCat(label: "🍅 Certified Fresh", tmdb: "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc"),
        DiscoverCat(label: "Netflix", tmdb: prov("movie", "8")),
        DiscoverCat(label: "Hulu", tmdb: prov("movie", "15")),
        DiscoverCat(label: "Max", tmdb: prov("movie", "1899")),
        DiscoverCat(label: "Prime Video", tmdb: prov("movie", "9")),
        DiscoverCat(label: "Apple TV+", tmdb: prov("movie", "350")),
        DiscoverCat(label: "Disney+", tmdb: prov("movie", "337")),
        DiscoverCat(label: "Paramount+", tmdb: prov("movie", "2303|2616|531")),
        DiscoverCat(label: "Peacock", tmdb: prov("movie", "386")),
    ]
    static let tv: [DiscoverCat] = [
        DiscoverCat(label: "Popular", cine: "top"),
        DiscoverCat(label: "Trending", tmdb: "trending/tv/week"),
        DiscoverCat(label: "For You", forYou: true),
        DiscoverCat(label: "New", cine: "year"),
        DiscoverCat(label: "Top Rated", cine: "imdbRating"),
        DiscoverCat(label: "New Shows", tmdb: "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25"),
        DiscoverCat(label: "Anime", tmdb: "discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc"),
        DiscoverCat(label: "Netflix", tmdb: prov("tv", "8")),
        DiscoverCat(label: "Hulu", tmdb: prov("tv", "15")),
        DiscoverCat(label: "Max", tmdb: prov("tv", "1899")),
        DiscoverCat(label: "Prime Video", tmdb: prov("tv", "9")),
        DiscoverCat(label: "Apple TV+", tmdb: prov("tv", "350")),
        DiscoverCat(label: "Disney+", tmdb: prov("tv", "337")),
        DiscoverCat(label: "Paramount+", tmdb: prov("tv", "2303|2616|531")),
        DiscoverCat(label: "Peacock", tmdb: prov("tv", "386")),
    ]
    static let movieGenres = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary",
                              "Drama", "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance",
                              "Sci-Fi", "Thriller", "War", "Western"]
    static let tvGenres = ["Action & Adventure", "Animation", "Comedy", "Crime", "Documentary",
                           "Drama", "Family", "Kids", "Mystery", "Reality", "Sci-Fi & Fantasy", "Soap", "Talk",
                           "War & Politics", "Western"]
}

struct BrowseView: View {
    @EnvironmentObject var session: Session
    var initialType: String = "movie"
    var initialGenre: String = ""
    @State private var type = "movie"                    // movie | series | anime
    @State private var catIdx = 0
    @State private var genre = ""
    @State private var year = 0                          // 0 = All years (TMDB discover reroute)
    @State private var anime: [(String, [Meta])] = []
    @State private var metas: [Meta] = []
    @State private var page = 0
    @State private var loading = false
    @State private var done = false
    @State private var booted = false
    @State private var gen = 0

    private var cats: [DiscoverCat] { type == "series" ? DiscoverCats.tv : DiscoverCats.movie }
    private var cat: DiscoverCat { cats[min(catIdx, cats.count - 1)] }
    private var genres: [String] { type == "series" ? DiscoverCats.tvGenres : DiscoverCats.movieGenres }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $type) {
                Text("Movies").tag("movie"); Text("Shows").tag("series"); Text("Anime").tag("anime")
            }
            .pickerStyle(.segmented).padding(.horizontal, Platform.gutter)
            .onChange(of: type) { _ in
                if type == "anime" { loadAnime(); return }
                catIdx = 0
                if !genres.contains(genre) { genre = "" }
                reload()
            }
            if type == "anime" {
                // Anime = TMDB Animation ∩ Japanese origin (Android "Anime" tab rows)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if let first = anime.first?.1, !first.isEmpty { HeroPager(metas: Array(first.prefix(6))) }
                        ForEach(anime, id: \.0) { row in PosterRow(title: row.0, metas: row.1) }
                        if anime.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                    }
                    .padding(.bottom, 28)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Android Discover dropdowns: catalog · genre · year
                        Menu {
                            ForEach(Array(cats.enumerated()), id: \.offset) { i, c in
                                Button(i == catIdx ? "✓ " + c.label : c.label) { catIdx = i; reload() }
                            }
                        } label: { dropdown(cat.label) }
                        Menu {
                            Button("All genres") { genre = ""; reload() }
                            ForEach(genres, id: \.self) { g in
                                Button(g == genre ? "✓ " + g : g) { genre = g; reload() }
                            }
                        } label: { dropdown(genre.isEmpty ? "All genres" : genre) }
                        Menu {
                            Button("All years") { year = 0; reload() }
                            ForEach(TMDB.years, id: \.self) { y in
                                Button(y == year ? "✓ \(String(y))" : String(y)) { year = y; reload() }
                            }
                        } label: { dropdown(year == 0 ? "All years" : String(year)) }
                    }
                    .padding(.horizontal, Platform.gutter)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let chunks = stride(from: 0, to: metas.count, by: 15).map { Array(metas[$0..<min($0 + 15, metas.count)]) }
                        ForEach(Array(chunks.enumerated()), id: \.offset) { i, chunk in
                            PosterRow(title: i == 0 ? cat.label : "", metas: chunk)
                                .onAppear { if i == chunks.count - 1 { loadMore() } }
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 20) }
                        if !loading && metas.isEmpty && done {
                            Text("Nothing here.").foregroundStyle(.secondary).padding(24)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .background(Theme.bg)
        .task {
            if !booted {
                booted = true
                type = initialType; genre = initialGenre
                if type == "anime" { loadAnime() }
            }
            if metas.isEmpty && type != "anime" { reload() }
        }
    }

    private func dropdown(_ label: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel, in: Capsule())
    }

    private func reload() {
        page = 0; done = false; metas = []; gen += 1; loading = false
        loadMore()
    }

    private func loadAnime() {
        guard anime.isEmpty else { return }
        Task {
            // Android animeDefs: Trending · Top Rated · Anime Movies · New Anime
            let defs: [(String, String, String)] = [
                ("Trending Anime", "tv", "with_genres=16&with_origin_country=JP&sort_by=popularity.desc"),
                ("Top Rated Anime", "tv", "with_genres=16&with_origin_country=JP&sort_by=vote_average.desc&vote_count.gte=500"),
                ("Anime Movies", "movie", "with_genres=16&with_origin_country=JP&sort_by=popularity.desc"),
                ("New Anime", "tv", "with_genres=16&with_origin_country=JP&sort_by=first_air_date.desc&vote_count.gte=25")]
            var out: [(String, [Meta])] = []
            for (label, kind, q) in defs {
                let items = await TMDB.row(kind: kind, "discover/\(kind)?" + q, pages: 1)
                if !items.isEmpty { out.append((label, items)); anime = out }
            }
        }
    }

    private func loadMore() {
        guard !loading, !done, type != "anime" else { return }
        loading = true
        let t = type, c = cat, pg = page, g = genre, y = year, myGen = gen
        Task {
            var batch: [Meta] = []
            let kind = t == "series" ? "tv" : "movie"
            if c.forYou {
                // For You never pages: the addon algo / rec graph / trending row (Android)
                if pg == 0 {
                    let (m, s) = await Catalog.forYouRows(session: session)
                    batch = t == "series" ? s : m
                }
            } else if y > 0 {
                // year reroutes through TMDB discover (Cinemeta can't year-filter, §1d)
                var q = "sort_by=popularity.desc&vote_count.gte=40&"
                q += kind == "tv" ? "first_air_date_year=\(y)" : "primary_release_year=\(y)"
                if !g.isEmpty, let gid = TMDB.genreId(g, kind: kind) { q += "&with_genres=\(gid)" }
                batch = await TMDB.discover(kind: kind, q, page: pg + 1)
            } else if var path = c.tmdb {
                if !g.isEmpty, let gid = TMDB.genreId(g, kind: kind) {
                    // TMDB's trending/ ignores with_genres — a genre-filtered trending row goes
                    // through discover, which honors it (Android tmdbRow)
                    if path.hasPrefix("trending/") { path = "discover/\(kind)?sort_by=popularity.desc&vote_count.gte=40&with_genres=\(gid)" }
                    else { path += (path.contains("?") ? "&" : "?") + "with_genres=\(gid)" }
                }
                batch = await TMDB.rowPage(kind: kind, path, page: pg + 1)
            } else {
                batch = await Catalog.cinemetaPage(type: t, id: c.cine.isEmpty ? "top" : c.cine,
                                                   genre: g.isEmpty ? nil : g, page: pg)
            }
            guard myGen == gen else { return }
            let fresh = batch.filter { b in !metas.contains { $0.id == b.id } }
            metas += fresh
            page += 1
            if batch.isEmpty || c.forYou { done = true }
            loading = false
        }
    }
}

/// The Discover tab (Android navTabs: Search · Home · Discover · …).
struct DiscoverTab: View {
    var body: some View {
        NavigationStack {
            BrowseView()
                .navigationTitle("Discover")
                .ckInlineTitle()
                .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
        }
    }
}
