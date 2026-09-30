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
        // GeometryReader pins the scroll content to EXACTLY the viewport width. Without it,
        // any async child (stream rows / episode rows) that lays out a point too wide made
        // the vertical ScrollView CENTER the whole page — everything "scooted" and clipped
        // at both edges the moment content loaded in (AJ Sep 30).
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                backdrop
                VStack(alignment: .leading, spacing: 14) {
                    header
                    genreChips
                    actionRow
                    castRow
                    if !session.canStream { whereToWatch }
                    if meta.type == "series" {
                        EpisodesView(meta: meta, videos: full["videos"] as? [[String: Any]] ?? [])
                    }
                    // STREAMS APPEAR AUTOMATICALLY (Stremio behavior) — only with a valid key.
                    if meta.type == "movie", session.canStream {
                        Text("Streams").font(.headline)
                        StreamList(meta: meta)
                    }
                }
                .padding(.horizontal, Platform.gutter).padding(.bottom, 20)
            }
            .frame(width: geo.size.width, alignment: .leading)
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
                Text("▶ Where to watch").font(.system(size: 20, weight: .bold)).padding(.top, 6)
                Text("Stream, rent, or buy from these services:").font(.footnote).foregroundStyle(.secondary)
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
            .frame(height: Platform.backdropHeight).frame(maxWidth: .infinity).clipped()
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
        .frame(height: Platform.backdropHeight)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterCard(meta: meta, width: Platform.posterWidth * 0.9)
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
        let genres = rich.genres.prefix(4)
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
            // opening the show clears its "+N" badge on EVERY device (web app.js parity —
            // dismissal = the latest aired season*10000+episode key, merged by max)
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let key = v.compactMap { Episode($0) }
                .filter { $0.season > 0 && Session.airMs($0.released) > 0 && Session.airMs($0.released) <= now }
                .map { $0.season * 10000 + $0.episode }.max() ?? 0
            session.dismissNewEpsBadge(meta.id, latestKey: key)
        }
        if !session.canStream {
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
                    .frame(width: Platform.actionSize, height: Platform.actionSize)
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

/// YouTube embed player in a web view (iPhone + Mac) — Android TrailerActivity: the
/// youtube-nocookie embed, inline playback, autoplay without a tap. The embed URL is loaded
/// directly (an about:blank-hosted iframe gets "Video unavailable"). Apple TV has no WKWebView;
/// the trailer button is hidden there.
struct YouTubeEmbed {
    let ytId: String
    private var url: URL? {
        // The bare embed URL answers "video player configuration error" on iOS WKWebView (no
        // real page origin). The service hosts a tiny wrapper page (same one Android-web uses)
        // whose https origin YouTube accepts.
        URL(string: API.serviceBase + "/player/trailer?v=\(ytId)")
    }
    #if !os(tvOS)
    fileprivate func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        #endif
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        #if os(iOS)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        #endif
        if let url { v.load(URLRequest(url: url)) }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
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
            }
            .padding(14)
            VStack(alignment: .leading, spacing: 4) {
                let movies = credits.filter { $0.type != "series" }
                let shows = credits.filter { $0.type == "series" }
                if !movies.isEmpty { PosterRow(title: "Movies", metas: movies) }
                if !shows.isEmpty { PosterRow(title: "Shows", metas: shows) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle(person.name)
        .ckInlineTitle()
        .task { credits = await TMDB.filmography(person.id); loading = false }
    }
}
