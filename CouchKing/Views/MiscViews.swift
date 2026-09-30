import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        #if os(tvOS)
        TVWhoIsWatching()          // Firestick "Who's watching?" (ProfilesTVMac.swift)
        #elseif os(macOS)
        MacProfileManager(gate: true)   // desktop profile manager card
        #else
        phonePicker
        #endif
    }

    // Android showProfilePicker: "Who's watching?", a row of 92dp faces with the name under
    // each, "＋ Add profile" while < 5, long-press a face to edit or remove it.
    @State private var edit: Profile?
    @State private var adding = false
    private var phonePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    BrandLockup(size: 64).padding(.top, 24)
                    Text("CouchKing TV").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.dim).padding(.top, 2)
                    Text("Who's watching?").font(.system(size: 28, weight: .bold)).padding(.top, 22).padding(.bottom, 26)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(session.profiles) { p in
                            Button { session.switchProfile(p.id); session.push() } label: {
                                VStack(spacing: 8) {
                                    FaceCircle(profile: p, size: 92)
                                    Text(p.name).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(1)
                                }
                                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit profile", systemImage: "pencil") { edit = p }
                                if session.profiles.count > 1 {
                                    Button("Delete profile", systemImage: "trash", role: .destructive) { session.deleteProfile(p.id) }
                                }
                            }
                        }
                        if session.profiles.count < 5 {
                            Button { adding = true } label: {
                                VStack(spacing: 8) {
                                    Text("＋").font(.system(size: 38)).foregroundStyle(Theme.dim)
                                        .frame(width: 92, height: 92)
                                        .background(Theme.card2, in: Circle())
                                        .overlay(Circle().stroke(Color(red: 0x4A / 255.0, green: 0x44 / 255.0, blue: 0x70 / 255.0), lineWidth: 2))
                                    Text("Add profile").font(.system(size: 15)).foregroundStyle(Theme.dim)
                                }
                                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 28)
                    Text("Hold a profile to edit or remove it.").font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
            .background(Theme.bg)
            .sheet(item: $edit) { p in NavigationStack { ProfileEditView(profile: p) } }
            .sheet(isPresented: $adding) { NavigationStack { ProfileEditView(profile: nil) } }
        }
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
            Text("People").font(.headline).padding(.horizontal, Platform.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Platform.isTV ? 40 : 12) {
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
                        .ckTile()
                    }
                }
                .padding(.horizontal, Platform.gutter)
                .padding(.vertical, Platform.isTV ? 36 : 0)   // room for the focus lift
            }
            .ckFocusSection()
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
                // plain VStack: LazyVStack deferred whole rows until you scrolled INTO them, so
                // library sections sat blank and "spawned in" (AJ). The list is bounded and the
                // posters inside each row are still lazy — only the row shells render eagerly.
                VStack(alignment: .leading, spacing: 18) {
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
                    .padding(.horizontal, Platform.gutter)
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
            if !title.isEmpty { Text(title).font(.headline).padding(.horizontal, Platform.gutter) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Platform.isTV ? 40 : 10) {
                    ForEach(metas) { m in
                        NavigationLink(value: m) {
                            PosterCard(meta: m, newEps: newEps[m.id]?.count ?? 0)
                        }.ckTile()
                    }
                }
                .padding(.horizontal, Platform.gutter)
                .padding(.vertical, Platform.isTV ? 36 : 0)   // room for the focus lift
            }
            .ckFocusSection()
        }
    }
}

/// Tuning screen (Android liveTune): logo + "Tuning ESPN… / Now: <program>" while the stream
/// list loads; then the access-gate probe + player. Back returns to the guide on this channel.
struct LiveTuneView: View {
    // STRAIGHT-THROUGH tune (Android liveTune): resolve the feed silently and open the
    // player — no visible "streams" page. Closing the player closes this too, so ✕ lands
    // back on the GUIDE, never on a stream list (AJ ×2).
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ckClose) private var ckClose
    let channel: Meta
    @State private var req: PlayRequest?
    @State private var gate = ""
    private func close() { if let ckClose { ckClose() } else { dismiss() } }
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if gate.isEmpty {
                VStack(spacing: 12) {
                    AsyncImage(url: URL(string: channel.logo ?? channel.poster ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: { Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary) }
                    .frame(height: 80)
                    Text("Tuning \(channel.name)…").font(.headline)
                    ProgressView()
                }
            } else {
                GateModal(text: gate) { close() }
            }
        }
        .task { await resolve() }
        .ckFullScreenCover(item: $req, onDismiss: { close() }) { PlayerView(request: $0) }
    }
    private func resolve() async {
        guard let base = session.addonBase() else { close(); return }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = try? await API.json("/stream/tv/\(channel.id).json?u=\(u)", base: base),
              let st = (r["streams"] as? [[String: Any]])?.first(where: { ($0["url"] as? String)?.isEmpty == false }),
              let us = st["url"] as? String, let url = URL(string: us) else {
            gate = "This channel has no feed right now."; return
        }
        let code = await API.probe(url)
        if let reason = API.gateReason(code) { gate = reason; return }
        req = PlayRequest(url: url, meta: channel, season: nil, episode: nil)
    }
}
