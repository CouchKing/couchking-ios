import SwiftUI
#if canImport(WebKit) && !os(tvOS)
import WebKit
#endif

// Details page — Android showDetail parity: backdrop with gradient, show LOGO instead of text
// when available, year · rating · runtime, genres as tappable chips (→ Discover pre-filtered),
// trailer / library / eye (movies) / 👍 / 👎 action circles, cast chips, then streams
// auto-loading INLINE for movies (Stremio behavior) or the episode list for shows.
struct DetailView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    @State private var full: [String: Any] = [:]
    @State private var trailerId: TrailerId?
    @Environment(\.openURL) private var openURL
    @State private var providers: TMDB.Providers?
    @State private var providersLoaded = false
    @State private var person: TMDB.Person?

    private var rich: Meta { Meta(full, type: meta.type) ?? meta }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                backdrop
                VStack(alignment: .leading, spacing: 14) {
                    header
                    genreChips
                    actionRow
                    if meta.type == "movie", session.hasAddon {
                        Text("Streams").font(.headline)
                        StreamList(meta: meta)
                    }
                    if !session.hasAddon { whereToWatch }
                    castRow
                    if meta.type == "series" {
                        EpisodesView(meta: meta, videos: full["videos"] as? [[String: Any]] ?? [])
                    }
                    if !session.hasAddon {
                        Text("Sign in with an enabled account to watch — tracking works for everyone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 20)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .task { await load() }
        .sheet(item: $trailerId) { t in TrailerView(ytId: t.id) }
        .sheet(item: $person) { p in
            NavigationStack {
                PersonView(person: p)
                    .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
            }
        }
    }

    /// Where-to-watch chips for guests/tracker users (IOS_CONTRACTS §1c): stream chips accented,
    /// "Rent · X" / "Buy · X" chips, all opening the JustWatch link; "🎬 In theaters now" gold
    /// notice for a recent movie with no providers. Hidden once an addon is installed.
    @ViewBuilder private var whereToWatch: some View {
        if let p = providers, !p.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("▶ Where to watch").font(.headline)
                let rent = Array(p.rent.prefix(4))
                let buy = Array(p.buy.filter { !rent.contains($0) }.prefix(4))
                let chips: [(String, Bool)] = p.stream.prefix(4).map { ($0, true) }
                    + rent.map { ("Rent · " + $0, false) } + buy.map { ("Buy · " + $0, false) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.0) { label, accent in
                            let chip = Text(label).font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(accent ? Theme.accent : Theme.card, in: Capsule())
                                .foregroundStyle(accent ? .white : .primary)
                            if Platform.isTV {
                                chip   // Apple TV has no browser: informational labels only
                            } else {
                                Button {
                                    if let l = p.link, let u = URL(string: l) { openURL(u) }
                                } label: { chip }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        } else if providersLoaded, meta.type == "movie", inTheaters {
            Text("🎬 In theaters now — home release hasn't happened yet")
                .font(.caption.bold()).foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.3))
        }
    }

    private var inTheaters: Bool {
        let year = Int((rich.releaseInfo ?? "").prefix(4)) ?? 0
        return year >= Calendar.current.component(.year, from: Date()) - 1
    }

    /// Backdrop image fading into the page, with the logo (or the name) sitting on it.
    @ViewBuilder private var backdrop: some View {
        let bg = rich.background ?? meta.background
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: bg ?? meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Theme.panel }
            .frame(height: 260).frame(maxWidth: .infinity).clipped()
            LinearGradient(colors: [.clear, Theme.bg.opacity(0.6), Theme.bg],
                           startPoint: .top, endPoint: .bottom)
            if let logo = rich.logo, let u = URL(string: logo) {
                AsyncImage(url: u) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 80, alignment: .leading)
                } placeholder: { Text(meta.name).font(.title2.bold()) }
                .padding(14)
            } else {
                Text(meta.name).font(.title2.bold()).padding(14)
            }
        }
        .frame(height: 260)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterCard(meta: meta, width: 96)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let y = rich.releaseInfo { Text(y) }
                    if let r = rich.imdbRating { Text("· ⭐ " + r) }
                    if let rt = rich.runtime, !rt.isEmpty { Text("· " + rt) }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(rich.description ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(8)
            }
        }
    }

    /// Genres as chips → Discover pre-filtered to that genre (Android genre chips deep-link).
    @ViewBuilder private var genreChips: some View {
        let genres = rich.genres.prefix(6)
        if !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(genres), id: \.self) { g in
                        NavigationLink {
                            BrowseView(initialType: meta.type == "series" ? "series" : "movie", initialGenre: g)
                                .navigationTitle(g)
                        } label: {
                            Text(g).font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Theme.accent.opacity(0.25), in: Capsule())
                                .overlay(Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            if let yt = ytId, !Platform.isTV {
                ActionCircle(icon: "film", active: false, label: "Trailer") { trailerId = TrailerId(id: yt) }
            }
            ActionCircle(icon: "plus.circle", active: session.inLibrary(meta.id),
                         label: session.inLibrary(meta.id) ? "In Library" : "Library") { session.toggleLibrary(meta) }
            if meta.type == "movie" {
                ActionCircle(icon: "eye", active: session.isWatched(meta.id), label: "Watched") { session.toggleWatched(meta) }
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
                    // cast chips → person page (TMDB person search by name, IOS_CONTRACTS §1)
                    ForEach(Array(cast), id: \.self) { nm in
                        Button {
                            Task { if let p = await TMDB.people(nm).first { person = p } }
                        } label: {
                            Text(nm).font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.card, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var ytId: String? {
        if let t = (full["trailers"] as? [[String: Any]])?.first?["source"] as? String { return t }
        return (full["trailerStreams"] as? [[String: Any]])?.first?["ytId"] as? String
    }
    private func load() async {
        // addon meta first (has videos for episodes); Cinemeta as guest fallback
        full = await Catalog.fullMeta(session: session, type: meta.type, id: meta.id)
        if meta.type == "series", let v = full["videos"] as? [[String: Any]] {
            MetaCache.shared.put(meta.id, videos: v)
        }
        if !session.hasAddon {
            providers = await TMDB.providers(imdb: meta.id, kind: meta.type == "series" ? "tv" : "movie")
            providersLoaded = true
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

/// In-app trailer (Android TrailerActivity / store flavors keep trailers in-app): the YouTube
/// embed player inside a web view — no bouncing out to Safari or the YouTube app.
struct TrailerId: Identifiable { let id: String }

struct TrailerView: View {
    @Environment(\.dismiss) private var dismiss
    let ytId: String
    var body: some View {
        NavigationStack {
            YouTubeEmbed(ytId: ytId)
                .background(.black)
                .navigationTitle("Trailer")
                .ckInlineTitle()
                .toolbar { ToolbarItem(placement: .ckTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// YouTube embed player in a web view (iPhone + Mac). Apple TV has no WKWebView; the trailer
/// button is hidden there.
struct YouTubeEmbed {
    let ytId: String
    private var html: String { """
        <html><body style="margin:0;background:#000">
        <iframe width="100%" height="100%" src="https://www.youtube.com/embed/\(ytId)?autoplay=1&playsinline=1&rel=0&modestbranding=1"
        frameborder="0" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """ }
    #if !os(tvOS)
    fileprivate func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        #endif
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        #if os(iOS)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        #endif
        v.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return v
    }
    #endif
}

#if os(iOS)
extension YouTubeEmbed: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWeb() }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#elseif os(macOS)
extension YouTubeEmbed: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWeb() }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
extension YouTubeEmbed: View { var body: some View { EmptyView() } }
#endif



/// Person page (Android showPerson): headshot, department, filmography grid resolved to IMDb ids.
struct PersonView: View {
    let person: TMDB.Person
    @State private var credits: [Meta] = []
    @State private var loading = true
    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 10)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    AsyncImage(url: URL(string: person.profile ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Theme.card.overlay(Image(systemName: "person.fill").foregroundStyle(.secondary)) }
                    .frame(width: 84, height: 84).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).font(.title3.bold())
                        if !person.known.isEmpty { Text(person.known).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Filmography").font(.headline)
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(credits) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }.ckTile()
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(14)
        }
        .background(Theme.bg)
        .navigationTitle(person.name)
        .ckInlineTitle()
        .task { credits = await TMDB.filmography(person.id); loading = false }
    }
}
