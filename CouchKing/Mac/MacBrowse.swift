#if os(macOS)
import SwiftUI

/// Rows of 15 poster strips (Discover / Library): label only on the first row.
struct DeskChunkedRows: View {
    let label: String
    let metas: [Meta]
    var newEps: [String: NewEpsInfo] = [:]
    var body: some View {
        let chunks = stride(from: 0, to: metas.count, by: 15).map { Array(metas[$0..<min($0 + 15, metas.count)]) }
        ForEach(Array(chunks.enumerated()), id: \.offset) { i, chunk in
            if i == 0 { DeskRowLabel(text: label) }
            DeskStrip {
                ForEach(chunk) { m in
                    NavigationLink(value: m) { DeskPoster(meta: m, newEps: newEps[m.id]?.count ?? 0) }.buttonStyle(.plain)
                }
            }
        }
    }
}

// Search (app.js): the input at top-left (max 480, autofocused), 400ms debounce, ≥2 chars;
// People strip (≤8 person cards) · Shows strip · Movies strip (25 each). No results → muted line.
struct MacSearch: View {
    @EnvironmentObject var session: Session
    @State private var q = ""
    @State private var people: [TMDB.Person] = []
    @State private var shows: [Meta] = []
    @State private var movies: [Meta] = []
    @State private var searched = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DeskField(placeholder: "Search movies & shows…", text: $q)
                    .padding(.top, 6.4)
                if !people.isEmpty {
                    DeskRowLabel(text: "People")
                    DeskStrip {
                        ForEach(people.prefix(8)) { p in
                            NavigationLink(value: p) { DeskPersonCard(person: p) }.buttonStyle(.plain)
                        }
                    }
                }
                if !shows.isEmpty {
                    DeskRowLabel(text: "Shows")
                    DeskStrip { ForEach(shows.prefix(25)) { m in NavigationLink(value: m) { DeskPoster(meta: m) }.buttonStyle(.plain) } }
                }
                if !movies.isEmpty {
                    DeskRowLabel(text: "Movies")
                    DeskStrip { ForEach(movies.prefix(25)) { m in NavigationLink(value: m) { DeskPoster(meta: m) }.buttonStyle(.plain) } }
                }
                if searched && people.isEmpty && shows.isEmpty && movies.isEmpty {
                    Text("No results for “\(q)”").foregroundStyle(Desk.muted).padding(.top, 16)
                }
            }
            .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Desk.bg)
        .onChange(of: q) { v in
            task?.cancel()
            let text = v.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { people = []; shows = []; movies = []; searched = false; return }
            task = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await run(text)
            }
        }
    }

    private func run(_ text: String) async {
        async let ppl = TMDB.people(text)
        var mv: [Meta] = [], sv: [Meta] = []
        let enc = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let base = session.addonBase() {
            let mc = session.catalogs.first { $0.type == "movie" && !$0.isLive }?.cid ?? "couchking-movies"
            let sc = session.catalogs.first { $0.type == "series" && !$0.isLive }?.cid ?? "couchking-series"
            async let m = API.json("/catalog/movie/\(mc)/search=\(enc).json", base: base)
            async let s = API.json("/catalog/series/\(sc)/search=\(enc).json", base: base)
            mv = Catalog.metas(try? await m, type: "movie"); sv = Catalog.metas(try? await s, type: "series")
        } else {
            async let m = API.json("/catalog/movie/top/search=\(enc).json", base: Catalog.cinemeta)
            async let s = API.json("/catalog/series/top/search=\(enc).json", base: Catalog.cinemeta)
            mv = Catalog.metas(try? await m, type: "movie"); sv = Catalog.metas(try? await s, type: "series")
        }
        let pv = await ppl
        guard q.trimmingCharacters(in: .whitespaces) == text else { return }
        people = pv; shows = sv; movies = mv; searched = true
    }
}

/// `.person-card`: 110px, 96px circle photo (accent outline on hover), name, muted role.
struct DeskPersonCard: View {
    let person: TMDB.Person
    @State private var hover = false
    var body: some View {
        VStack(spacing: 5.6) {
            AsyncImage(url: URL(string: person.profile ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Desk.card.overlay(Text("👤").font(.system(size: 32))) }
            .frame(width: 96, height: 96).clipShape(Circle())
            .overlay(Circle().stroke(Desk.accent, lineWidth: hover ? 2 : 0))
            Text(person.name).font(.system(size: 12.8, weight: .semibold)).foregroundStyle(Desk.text2)
                .lineLimit(1).frame(width: 110)
            Text(person.known == "Directing" ? "Director" : "Actor")
                .font(.system(size: 11.5, weight: .bold)).foregroundStyle(Desk.muted)
        }
        .frame(width: 110)
        .onHover { hover = $0 }
    }
}

// Discover (app.js): `.pickers` — Type · Catalog · Genre · Year selects with muted labels;
// results in rows of 15, first label "Catalog · Genre · Year", up to 400 items.
struct MacDiscover: View {
    @EnvironmentObject var session: Session
    @State private var type = "movie"
    @State private var catalog = ""
    @State private var genre = ""
    @State private var year = 0
    @State private var metas: [Meta] = []
    @State private var loading = false

    private var catalogs: [AddonCatalog] {
        if session.canStream { return session.catalogs.filter { $0.type == type && !$0.isLive && !$0.searchOnly } }
        return [AddonCatalog(["type": type, "id": "top", "name": "Popular"]),
                AddonCatalog(["type": type, "id": "year", "name": "New"])].compactMap { $0 }
    }
    private var current: AddonCatalog? { catalogs.first { $0.cid == catalog } ?? catalogs.first }
    private var genres: [String] {
        let g = current?.genres ?? []
        return g.isEmpty ? (type == "series" ? TMDB.tvGenres : TMDB.movieGenres).map { $0.0 } : g
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11.2) {
                    picker("Type", selection: $type, options: [("movie", "Movies"), ("series", "TV Series")])
                    picker("Catalog", selection: $catalog, options: catalogs.map { ($0.cid, $0.name) })
                    picker("Genre", selection: $genre, options: [("", "All genres")] + genres.map { ($0, $0) })
                    picker("Year", selection: $year, options: [(0, "All years")] + TMDB.years.map { ($0, String($0)) })
                    Spacer()
                }
                .padding(.top, 4.8).padding(.bottom, 9.6)
                if !metas.isEmpty {
                    DeskChunkedRows(label: resultLabel, metas: Array(metas.prefix(400)))
                }
                if loading { ProgressView().padding(24) }
            }
            .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
        }
        .background(Desk.bg)
        .task(id: "\(type)|\(catalog)|\(genre)|\(year)|\(session.catalogs.count)") { await load() }
        .onChange(of: type) { _ in catalog = catalogs.first?.cid ?? ""; genre = "" }
    }

    private var resultLabel: String {
        [current?.name ?? "", genre.isEmpty ? nil : genre, year == 0 ? nil : String(year)].compactMap { $0 }.joined(separator: " · ")
    }

    /// `<label>` muted .85rem/700 + `<select>` (card bg, 1px #37315C, r10, .95rem/700).
    private func picker<T: Hashable>(_ label: String, selection: Binding<T>, options: [(T, String)]) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 13.6, weight: .bold)).foregroundStyle(Desk.muted)
            Menu {
                ForEach(options, id: \.0) { v, name in Button(name) { selection.wrappedValue = v } }
            } label: {
                Text(options.first { $0.0 == selection.wrappedValue }?.1 ?? options.first?.1 ?? "")
                    .font(.system(size: 15.2, weight: .bold)).foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 14.4).padding(.vertical, 9.6)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Desk.border, lineWidth: 1))
        }
    }

    private func load() async {
        guard let c = current else { metas = []; return }
        loading = true
        var out: [Meta] = []
        if year > 0 {
            let kind = type == "series" ? "tv" : "movie"
            var q = "sort_by=popularity.desc&vote_count.gte=40&"
            q += kind == "tv" ? "first_air_date_year=\(year)" : "primary_release_year=\(year)"
            if !genre.isEmpty, let gid = TMDB.genreId(genre, kind: kind) { q += "&with_genres=\(gid)" }
            for page in 1...4 { out += await TMDB.discover(kind: kind, q, page: page) }
        } else {
            var skip = 0
            while out.count < 120 {
                var extras: [String] = []
                if !genre.isEmpty { extras.append("genre=" + (genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre)) }
                if skip > 0 { extras.append("skip=\(skip)") }
                let extra = extras.joined(separator: "&")
                let batch = session.canStream
                    ? await Catalog.fetch(session: session, type: type, cid: c.cid, extra: extra)
                    : await Catalog.guestRow(type, extra.isEmpty ? c.cid : c.cid + "/" + extra)
                if batch.isEmpty { break }
                out += batch.filter { b in !out.contains { $0.id == b.id } }
                skip += batch.count
            }
        }
        metas = out
        loading = false
    }
}

// Library (app.js): search input · chips All/Movies/Shows + "↕ <sort>" chip cycling Recent →
// New episodes → A–Z → Z–A → Watched → Unwatched · rows of 15, Movies first then Shows, +N badges.
struct MacLibrary: View {
    @EnvironmentObject var session: Session
    @State private var q = ""
    @State private var filter = "all"
    @State private var sort = 0
    @State private var newEps: [String: NewEpsInfo] = [:]
    private let sorts = ["Recent", "New episodes", "A–Z", "Z–A", "Watched", "Unwatched"]

    private var watchlist: [Meta] {
        (session.pstate()["watchlist"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: "movie") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !session.signedIn {
                    Text("Your library lives on your account — sign in to see it.").foregroundStyle(Desk.muted).padding(.top, 16)
                } else {
                    DeskField(placeholder: "Search your library…", text: $q).padding(.top, 6.4)
                    HStack(spacing: 0) {
                        ForEach([("all", "All"), ("movie", "Movies"), ("series", "Shows")], id: \.0) { k, label in
                            DeskChip(text: label, on: filter == k) { filter = k }.padding(.trailing, 8)
                        }
                        DeskChip(text: "↕ " + sorts[sort], white: true) { sort = (sort + 1) % sorts.count }
                    }
                    .padding(.top, 11.2).padding(.bottom, 3.2)
                    if filter != "series" { DeskChunkedRows(label: "Movies", metas: visible("movie"), newEps: newEps) }
                    if filter != "movie" { DeskChunkedRows(label: "Shows", metas: visible("series"), newEps: newEps) }
                }
            }
            .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Desk.bg)
        .task(id: watchlist.map(\.id).joined()) {
            var out: [String: NewEpsInfo] = [:]
            for m in watchlist where m.type == "series" {
                let info = session.newEpisodes(for: m, videos: await MetaCache.shared.videos(for: m, session: session))
                if info.count > 0 { out[m.id] = info }
            }
            newEps = out
        }
    }

    private func visible(_ type: String) -> [Meta] {
        var list = watchlist.filter { $0.type == type }
        let text = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty { list = list.filter { $0.name.lowercased().contains(text) } }
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
#endif
