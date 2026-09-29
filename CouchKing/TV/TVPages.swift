#if os(tvOS)
import SwiftUI

/// The rows region shared by every board page: vertical scroll under the board line, with the
/// rail inset + Firestick rows padding (left 10dp after the 64dp rail, right 26dp, bottom =
/// screen height so any row can scroll up to the line).
struct TVRows<Content: View>: View {
    @ViewBuilder let content: (ScrollViewProxy) -> Content
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content(proxy)
                    Color.clear.frame(height: 1080)
                }
                .padding(.leading, TV.dp(64 + 10)).padding(.trailing, TV.dp(26)).padding(.top, TV.dp(2))
            }
        }
    }
}

// Home (buildShelvesInto ~2655): Continue Watching (initial focus) · Top 10 Today · For You —
// Movies · For You — Shows · the person's shelves in their order. Rows fill top-down, no skeletons.
struct TVHome: View {
    @EnvironmentObject var session: Session
    @StateObject private var board = BoardModel()
    @State private var cw: [CWItem] = []
    @State private var top10: [Meta] = []
    @State private var rows: [(String, [Meta])] = []
    @State private var loadGen = 0
    @State private var resume: CWItem?
    @Namespace private var ns

    var body: some View {
        TVBoard(model: board) {
            TVRows { page in
                if session.hasAddon && !cw.isEmpty {
                    TVRow(id: "cw", label: "Continue Watching", page: page) {
                        ForEach(Array(cw.enumerated()), id: \.element.id) { i, item in
                            TVTile(meta: item.meta, rowId: "cw", page: page, model: board,
                                   progress: item.progress, newEps: item.newEps, inContinue: true) {
                                session.dismissNewEpsBadge(item.meta.id, latestAir: item.latestAir)
                                resume = item   // resumeFromCw: play straight away
                            }
                            .prefersDefaultFocus(i == 0, in: ns)
                        }
                    }
                }
                if !top10.isEmpty {
                    TVRow(id: "top10", label: "Top 10 Today", labelSize: 17, page: page) {
                        ForEach(Array(top10.enumerated()), id: \.element.id) { i, m in
                            TVTop10Tile(rank: i + 1, meta: m, rowId: "top10", page: page, model: board)
                        }
                    }
                }
                ForEach(rows, id: \.0) { row in
                    TVRow(id: row.0, label: row.0, page: page) {
                        ForEach(row.1) { m in TVTile(meta: m, rowId: row.0, page: page, model: board) }
                    }
                }
            }
        }
        .focusScope(ns)
        .onAppear { board.session = session }
        .task(id: "\(session.currentProfile)|\(session.homeStale)|\(session.addons.first?.url ?? "")") { await load() }
        .onReceive(session.objectWillChange) { _ in Task { cw = await session.continueWatchingOrdered() } }
        .fullScreenCover(item: $resume) { item in
            let p = item.resumeKey.split(separator: ":")
            StreamSheet(meta: item.meta, season: p.count >= 3 ? Int(p[p.count - 2]) : nil,
                        episode: p.count >= 3 ? Int(p[p.count - 1]) : nil, autoplay: true)
        }
    }

    private func load() async {
        board.session = session
        loadGen += 1
        let gen = loadGen
        cw = session.hasAddon ? await session.continueWatchingOrdered() : []
        // trending movies + tv of the day, interleaved: first 10 = Top 10, first 8 = showcase
        async let tm = TMDB.trendingDay(kind: "movie")
        async let tt = TMDB.trendingDay(kind: "tv")
        let pool = Catalog.interleave(await tm, await tt, count: 20)
        guard gen == loadGen else { return }
        top10 = Array(pool.prefix(10))
        board.startShowcase(Array(pool.prefix(8)))
        var fresh: [(String, [Meta])] = []
        rows = []
        if session.hasAddon {
            for (title, cat) in Catalog.homeLineup(session: session) {
                var metas = await Catalog.shelf(session: session, cat)
                guard gen == loadGen else { return }
                if metas.isEmpty { continue }
                if !cat.isForYou && !cat.isOrdered && cat.curated.isEmpty {
                    metas = Catalog.mix(metas, session: session, salt: cat.id)
                }
                fresh.append((title, Array(metas.prefix(60))))
                rows = fresh
            }
        } else {
            let fy = await Catalog.guestForYou(session: session)
            if !fy.isEmpty { fresh.append(("For You", fy)); rows = fresh }
            for (title, type, path) in Catalog.guestRows {
                let metas = await Catalog.guestRow(type, path)
                guard gen == loadGen else { return }
                if metas.isEmpty { continue }
                fresh.append((title, Catalog.mix(metas, session: session, salt: title)))
                rows = fresh
            }
            for cat in session.enabledShelves() where !cat.curated.isEmpty {
                let metas = await Catalog.shelf(session: session, cat)
                guard gen == loadGen else { return }
                if !metas.isEmpty { fresh.append((cat.name, metas)); rows = fresh }
            }
        }
    }
}

/// Chunk a list into rows of 15 (Library / Discover); only the first row is labelled.
struct TVChunked: View {
    let idBase: String
    let label: String
    let metas: [Meta]
    let page: ScrollViewProxy
    @ObservedObject var board: BoardModel
    var newEps: [String: NewEpsInfo] = [:]
    var body: some View {
        let chunks = stride(from: 0, to: metas.count, by: 15).map { Array(metas[$0..<min($0 + 15, metas.count)]) }
        ForEach(Array(chunks.enumerated()), id: \.offset) { i, chunk in
            let rid = "\(idBase)-\(i)"
            TVRow(id: rid, label: i == 0 ? label : nil, page: page) {
                ForEach(chunk) { m in TVTile(meta: m, rowId: rid, page: page, model: board, newEps: newEps[m.id]?.count ?? 0) }
            }
        }
    }
}

// Search (buildSearch ~2896): field selBg(#1B1830, 8dp, ACCENT ring), live search 450ms, ≥2
// chars; People row (96dp cards, 76dp circle photos) · Shows row · Movies row.
struct TVSearch: View {
    @EnvironmentObject var session: Session
    @StateObject private var board = BoardModel()
    @State private var q = ""
    @State private var people: [TMDB.Person] = []
    @State private var shows: [Meta] = []
    @State private var movies: [Meta] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        TVBoard(model: board) {
            TVRows { page in
                TextField("Search movies & shows…", text: $q)
                    .font(.system(size: TV.sp(15)))
                    .padding(TV.dp(12))
                    .background(TV.card, in: RoundedRectangle(cornerRadius: TV.dp(8)))
                    .frame(width: TV.dp(520))
                    .padding(.leading, TV.dp(14)).padding(.top, TV.dp(8)).padding(.bottom, TV.dp(8))
                if !people.isEmpty {
                    TVRow(id: "people", label: "People", page: page) {
                        ForEach(people.prefix(12)) { p in
                            NavigationLink(value: p) { TVPersonCard(person: p) }
                                .buttonStyle(TVScaleButton(scale: 1.1, duration: 0.11))
                                .padding(.horizontal, TV.dp(8))
                        }
                    }
                }
                if !shows.isEmpty {
                    TVRow(id: "shows", label: "Shows", page: page) {
                        ForEach(shows.prefix(25)) { m in TVTile(meta: m, rowId: "shows", page: page, model: board) }
                    }
                }
                if !movies.isEmpty {
                    TVRow(id: "movies", label: "Movies", page: page) {
                        ForEach(movies.prefix(25)) { m in TVTile(meta: m, rowId: "movies", page: page, model: board) }
                    }
                }
            }
        }
        .onAppear { board.session = session }
        .onChange(of: q) { v in
            task?.cancel()
            let text = v.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { people = []; shows = []; movies = []; return }
            task = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                async let ppl = TMDB.people(text)
                let enc = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                var mv: [Meta] = [], sv: [Meta] = []
                if let base = session.addonBase() {
                    let mc = session.catalogs.first { $0.type == "movie" && !$0.isLive }?.cid ?? "couchking-movies"
                    let sc = session.catalogs.first { $0.type == "series" && !$0.isLive }?.cid ?? "couchking-series"
                    mv = Catalog.metas(try? await API.json("/catalog/movie/\(mc)/search=\(enc).json", base: base), type: "movie")
                    sv = Catalog.metas(try? await API.json("/catalog/series/\(sc)/search=\(enc).json", base: base), type: "series")
                } else {
                    mv = Catalog.metas(try? await API.json("/catalog/movie/top/search=\(enc).json", base: Catalog.cinemeta), type: "movie")
                    sv = Catalog.metas(try? await API.json("/catalog/series/top/search=\(enc).json", base: Catalog.cinemeta), type: "series")
                }
                let pv = await ppl
                guard q.trimmingCharacters(in: .whitespaces) == text else { return }
                people = pv; shows = sv; movies = mv
                if let first = sv.first ?? mv.first { board.narrate(first, user: false) }
            }
        }
    }
}

/// Person card: 96dp wide, 76dp circle photo, name 11.5sp, role 10sp #A9A5C0.
struct TVPersonCard: View {
    let person: TMDB.Person
    var body: some View {
        VStack(spacing: TV.dp(4)) {
            AsyncImage(url: URL(string: person.profile ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { TV.card.overlay(Image(systemName: "person.fill").foregroundStyle(TV.dim)) }
            .frame(width: TV.dp(76), height: TV.dp(76)).clipShape(Circle())
            Text(person.name).font(.system(size: TV.sp(11.5))).foregroundStyle(.white).lineLimit(1)
            Text(person.known == "Directing" ? "Director" : "Actor").font(.system(size: TV.sp(10))).foregroundStyle(TV.dim)
        }
        .frame(width: TV.dp(96))
    }
}

// Discover (buildDiscover ~3145): four "Label  ▾" dropdowns (14.5sp bold, selBg #241F3D r10dp)
// Type · Catalog · Genre · Year, then results in rows of 15 labelled with the catalog name.
struct TVDiscover: View {
    @EnvironmentObject var session: Session
    @StateObject private var board = BoardModel()
    @State private var type = "movie"
    @State private var catalog = ""
    @State private var genre = ""
    @State private var year = 0
    @State private var metas: [Meta] = []

    private var catalogs: [AddonCatalog] {
        if session.hasAddon { return session.catalogs.filter { $0.type == type && !$0.isLive && !$0.searchOnly } }
        return [AddonCatalog(["type": type, "id": "top", "name": "Popular"]),
                AddonCatalog(["type": type, "id": "year", "name": "New"])].compactMap { $0 }
    }
    private var current: AddonCatalog? { catalogs.first { $0.cid == catalog } ?? catalogs.first }
    private var genres: [String] {
        let g = current?.genres ?? []
        return g.isEmpty ? (type == "series" ? TMDB.tvGenres : TMDB.movieGenres).map { $0.0 } : g
    }

    var body: some View {
        TVBoard(model: board) {
            TVRows { page in
                HStack(spacing: TV.dp(10)) {
                    dropdown(type == "movie" ? "Movies" : "TV Series", [("movie", "Movies"), ("series", "TV Series")]) { type = $0; catalog = ""; genre = "" }
                    dropdown(current?.name ?? "Catalog", catalogs.map { ($0.cid, $0.name) }) { catalog = $0 }
                    dropdown(genre.isEmpty ? "All genres" : genre, [("", "All genres")] + genres.map { ($0, $0) }) { genre = $0 }
                    dropdown(year == 0 ? "All years" : String(year), [("0", "All years")] + TMDB.years.map { (String($0), String($0)) }) { year = Int($0) ?? 0 }
                }
                .padding(.leading, TV.dp(12)).padding(.top, TV.dp(10)).padding(.bottom, TV.dp(6))
                .focusSection()
                if !metas.isEmpty {
                    TVChunked(idBase: "disc", label: current?.name ?? "", metas: metas, page: page, board: board)
                }
            }
        }
        .onAppear { board.session = session }
        .task(id: "\(type)|\(catalog)|\(genre)|\(year)|\(session.catalogs.count)") { await load() }
    }

    private func dropdown(_ label: String, _ options: [(String, String)], pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { v, name in Button(name) { pick(v) } }
        } label: {
            Text(label + "  ▾").font(.system(size: TV.sp(14.5), weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, TV.dp(14)).padding(.vertical, TV.dp(9))
                .background(TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(10)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(10)))
    }

    private func load() async {
        board.session = session
        guard let c = current else { metas = []; return }
        var out: [Meta] = []
        if year > 0 {
            let kind = type == "series" ? "tv" : "movie"
            var q = "sort_by=popularity.desc&vote_count.gte=40&"
            q += kind == "tv" ? "first_air_date_year=\(year)" : "primary_release_year=\(year)"
            if !genre.isEmpty, let gid = TMDB.genreId(genre, kind: kind) { q += "&with_genres=\(gid)" }
            for pg in 1...3 { out += await TMDB.discover(kind: kind, q, page: pg) }
        } else {
            var skip = 0
            while out.count < 90 {
                var extras: [String] = []
                if !genre.isEmpty { extras.append("genre=" + (genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre)) }
                if skip > 0 { extras.append("skip=\(skip)") }
                let extra = extras.joined(separator: "&")
                let batch = session.hasAddon
                    ? await Catalog.fetch(session: session, type: type, cid: c.cid, extra: extra)
                    : await Catalog.guestRow(type, extra.isEmpty ? c.cid : c.cid + "/" + extra)
                if batch.isEmpty { break }
                out += batch.filter { b in !out.contains { $0.id == b.id } }
                skip += batch.count
            }
        }
        metas = out
        if let f = out.first { board.narrate(f, user: false) }
    }
}

// Library (buildLibrary ~3011): chips All / Movies / Shows (accent when on, #2C2649 off) + the
// sort chip "↕ Recent" cycling Recent → New episodes → A–Z → Z–A → Watched → Unwatched; rows of
// 15, Movies then Shows. No search field on TV.
struct TVLibrary: View {
    @EnvironmentObject var session: Session
    @StateObject private var board = BoardModel()
    @State private var filter = "all"
    @State private var sort = 0
    @State private var newEps: [String: NewEpsInfo] = [:]
    private let sorts = ["Recent", "New episodes", "A–Z", "Z–A", "Watched", "Unwatched"]

    private var watchlist: [Meta] {
        (session.pstate()["watchlist"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
    }

    var body: some View {
        TVBoard(model: board) {
            TVRows { page in
                HStack(spacing: TV.dp(8)) {
                    ForEach([("all", "All"), ("movie", "Movies"), ("series", "Shows")], id: \.0) { k, label in
                        chip(label, on: filter == k) { filter = k }
                    }
                    chip("↕ " + sorts[sort], on: false, white: true) { sort = (sort + 1) % sorts.count }
                }
                .padding(.leading, TV.dp(12)).padding(.top, TV.dp(6)).padding(.bottom, TV.dp(6))
                .focusSection()
                if watchlist.isEmpty {
                    Text("Titles you add to your Library show up here.").font(.system(size: TV.sp(14)))
                        .foregroundStyle(TV.dim).padding(TV.dp(12))
                }
                if filter != "series" { TVChunked(idBase: "lm", label: "Movies", metas: visible("movie"), page: page, board: board, newEps: newEps) }
                if filter != "movie" { TVChunked(idBase: "ls", label: "Shows", metas: visible("series"), page: page, board: board, newEps: newEps) }
            }
        }
        .onAppear { board.session = session }
        .task(id: watchlist.map(\.id).joined()) {
            board.session = session
            if let f = watchlist.first { board.narrate(f, user: false) }
            var out: [String: NewEpsInfo] = [:]
            for m in watchlist where m.type == "series" {
                let info = session.newEpisodes(for: m, videos: await MetaCache.shared.videos(for: m, session: session))
                if info.count > 0 { out[m.id] = info }
            }
            newEps = out
        }
    }

    private func chip(_ text: String, on: Bool, white: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: TV.sp(14), weight: on || white ? .bold : .regular))
                .foregroundStyle(on || white ? .white : TV.dim)
                .padding(.horizontal, TV.dp(14)).padding(.vertical, TV.dp(8))
                .background(on ? TV.accent : TV.chip, in: RoundedRectangle(cornerRadius: TV.dp(16)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(16)))
    }

    private func visible(_ type: String) -> [Meta] {
        var list = watchlist.filter { $0.type == type }
        let added = session.pstate()["addedTs"] as? [String: Any] ?? [:]
        switch sort {
        case 1: list = list.filter { (newEps[$0.id]?.count ?? 0) > 0 }.sorted { (newEps[$0.id]?.count ?? 0) > (newEps[$1.id]?.count ?? 0) }
        case 2: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case 3: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case 4: list = list.filter { session.isWatched($0.id) }
        case 5: list = list.filter { !session.isWatched($0.id) }
        default: list.sort { StateMerge.stamp(added["wl:" + $0.id]) > StateMerge.stamp(added["wl:" + $1.id]) }
        }
        return list
    }
}

/// Person page: the board with "Shows" and "Movies" rows.
struct TVPerson: View {
    @EnvironmentObject var session: Session
    let person: TMDB.Person
    @StateObject private var board = BoardModel()
    @State private var credits: [Meta] = []
    var body: some View {
        TVBoard(model: board) {
            TVRows { page in
                ForEach([("Shows", "series"), ("Movies", "movie")], id: \.0) { label, type in
                    let list = credits.filter { $0.type == type }
                    if !list.isEmpty {
                        TVRow(id: label, label: label, page: page) {
                            ForEach(list) { m in TVTile(meta: m, rowId: label, page: page, model: board) }
                        }
                    }
                }
            }
        }
        .task {
            board.session = session
            credits = await TMDB.filmography(person.id)
            if let f = credits.first { board.narrate(f, user: false) }
        }
    }
}
#endif
