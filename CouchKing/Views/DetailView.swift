import SwiftUI
import WebKit

// Details page — Android showDetail parity: backdrop with gradient, show LOGO instead of text
// when available, year · rating · runtime, genres as tappable chips (→ Discover pre-filtered),
// trailer / library / eye (movies) / 👍 / 👎 action circles, cast chips, then streams
// auto-loading INLINE for movies (Stremio behavior) or the episode list for shows.
struct DetailView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    @State private var full: [String: Any] = [:]
    @State private var trailerId: TrailerId?

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
            if let yt = ytId {
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
    private func load() async {
        // addon meta first (has videos for episodes); Cinemeta as guest fallback
        full = await Catalog.fullMeta(session: session, type: meta.type, id: meta.id)
        if meta.type == "series", let v = full["videos"] as? [[String: Any]] {
            MetaCache.shared.put(meta.id, videos: v)
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
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct YouTubeEmbed: UIViewRepresentable {
    let ytId: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        let html = """
        <html><body style="margin:0;background:#000">
        <iframe width="100%" height="100%" src="https://www.youtube.com/embed/\(ytId)?autoplay=1&playsinline=1&rel=0&modestbranding=1"
        frameborder="0" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

