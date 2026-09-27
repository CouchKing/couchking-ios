import SwiftUI

// Discover (Android buildDiscover + Movies·Shows tabs): Movies/Shows segment, a catalog picker
// (every browsable catalog the addon manifest exposes — nothing hardcoded), a genre dropdown
// from the catalog's manifest `extra` options, rendered as a skip-paginated poster grid.
// Guests browse Cinemeta's catalogs instead (tracker mode). Genre chips on Details deep-link here.
struct BrowseView: View {
    @EnvironmentObject var session: Session
    var initialType: String = "movie"
    var initialGenre: String = ""
    @State private var type = "movie"                    // movie | series
    @State private var collection = ""
    @State private var genre = ""
    @State private var metas: [Meta] = []
    @State private var skip = 0
    @State private var loading = false
    @State private var done = false
    @State private var booted = false

    /// Catalogs for the current type: the manifest's, or Cinemeta's for guests.
    private var collections: [AddonCatalog] {
        if session.hasAddon {
            return session.catalogs.filter { $0.type == type && !$0.isLive && !$0.searchOnly }
        }
        let g = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama",
                 "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance",
                 "Sci-Fi", "Thriller", "War", "Western"]
        return [AddonCatalog(["type": type, "id": "top", "name": "🔥 Popular", "genres": g]),
                AddonCatalog(["type": type, "id": "year", "name": "🆕 New this year", "genres": g])].compactMap { $0 }
    }
    private var current: AddonCatalog? { collections.first { $0.cid == collection } ?? collections.first }
    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $type) {
                Text("Movies").tag("movie"); Text("Shows").tag("series")
            }
            .pickerStyle(.segmented).padding(.horizontal, 14)
            .onChange(of: type) { _ in
                collection = collections.first?.cid ?? ""
                if !(current?.genres.contains(genre) ?? false) { genre = "" }
                reload()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(collections) { c in
                        Button(c.name) { collection = c.cid; if !c.genres.contains(genre) { genre = "" }; reload() }
                            .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(current?.cid == c.cid ? Theme.accent : Theme.card, in: Capsule())
                            .foregroundStyle(current?.cid == c.cid ? .white : .primary)
                    }
                }.padding(.horizontal, 14)
            }
            if let c = current, !c.genres.isEmpty {
                // genre dropdown (Android Discover dropdowns) — driven by the manifest's extra options
                Menu {
                    Button("All genres") { genre = ""; reload() }
                    ForEach(c.genres, id: \.self) { g in
                        Button(g == genre ? "✓ " + g : g) { genre = g; reload() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(genre.isEmpty ? "All genres" : genre).font(.caption)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.panel, in: Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(metas) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }.buttonStyle(.plain)
                            .onAppear { if m.id == metas.last?.id { loadMore() } }
                    }
                }
                .padding(.horizontal, 14)
                if loading { ProgressView().padding(.top, 20) }
                if !loading && metas.isEmpty && done {
                    Text("Nothing here yet.").foregroundStyle(.secondary).padding(24)
                }
            }
        }
        .background(Theme.bg)
        .task(id: session.catalogs.count) {
            if !booted {
                booted = true
                type = initialType; genre = initialGenre
            }
            if metas.isEmpty { collection = collections.first?.cid ?? ""; reload() }
        }
    }

    private func reload() {
        skip = 0; done = false; metas = []; loadMore()
    }

    private func loadMore() {
        guard !loading, !done, let c = current else { return }
        loading = true
        let t = type, id = c.cid, s = skip, g = genre
        Task {
            var extras: [String] = []
            if !g.isEmpty { extras.append("genre=" + (g.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? g)) }
            if s > 0 { extras.append("skip=\(s)") }
            let extra = extras.joined(separator: "&")
            let batch: [Meta]
            if session.hasAddon {
                batch = await Catalog.fetch(session: session, type: t, cid: id, extra: extra)
            } else {
                batch = await Catalog.guestRow(t, extra.isEmpty ? id : id + "/" + extra)
            }
            // guard against a stale response after the user switched type/collection/genre
            if t == type && id == current?.cid && g == genre {
                metas += batch
                skip += batch.count
                if batch.isEmpty { done = true }
            }
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
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
        }
    }
}
