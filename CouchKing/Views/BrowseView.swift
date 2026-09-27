import SwiftUI

// Browse / Discover (Android Movies·Shows tabs + Discover): a Movies/Shows segment and a
// collection picker (Trending, Fresh, Top, New, + the per-service catalogs the addon exposes),
// rendered as a paginated poster grid. Shown as the Search tab's empty state.
struct BrowseView: View {
    @EnvironmentObject var session: Session
    @State private var type = "movie"                    // movie | series
    @State private var collection = "couchking-movies"
    @State private var metas: [Meta] = []
    @State private var skip = 0
    @State private var loading = false
    @State private var done = false

    // (catalog id, label). Trending is type-specific; the rest share one id across both types.
    private var collections: [(String, String)] {
        [(type == "movie" ? "couchking-movies" : "couchking-series", "🔥 Trending"),
         ("ck-fresh", "🍅 Fresh"), ("ck-top", "⭐ Top"), ("ck-new", type == "movie" ? "🎬 New" : "🆕 New"),
         ("ck-netflix", "Netflix"), ("ck-hulu", "Hulu"), ("ck-disney", "Disney+"),
         ("ck-paramount", "Paramount+"), ("ck-hbomax", "HBO Max"), ("ck-prime", "Prime"),
         ("ck-appletv", "Apple TV+"), ("ck-peacock", "Peacock")]
    }
    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $type) {
                Text("Movies").tag("movie"); Text("Shows").tag("series")
            }
            .pickerStyle(.segmented).padding(.horizontal, 14)
            .onChange(of: type) { _ in
                collection = collections[0].0; reload()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(collections, id: \.0) { id, label in
                        Button(label) { collection = id; reload() }
                            .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(collection == id ? Theme.accent : Theme.card, in: Capsule())
                            .foregroundStyle(collection == id ? .white : .primary)
                    }
                }.padding(.horizontal, 14)
            }
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(metas) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }
                            .onAppear { if m.id == metas.last?.id { loadMore() } }
                    }
                }
                .padding(.horizontal, 14)
                if loading { ProgressView().padding(.top, 20) }
            }
        }
        .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
        .task { if metas.isEmpty { reload() } }
    }

    private func reload() {
        skip = 0; done = false; metas = []; loadMore()
    }

    private func loadMore() {
        guard !loading, !done, let addon = session.addons.first else { return }
        loading = true
        let t = type, id = collection, s = skip
        Task {
            let path = s > 0 ? "/catalog/\(t)/\(id)/skip=\(s).json" : "/catalog/\(t)/\(id).json"
            let r = (try? await API.json(path, base: addon.url)) ?? [:]
            let batch = (r["metas"] as? [[String: Any]] ?? []).compactMap { Meta($0, type: t) }
            // guard against a stale response after the user switched type/collection
            if t == type && id == collection {
                metas += batch
                skip += batch.count
                if batch.isEmpty { done = true }
            }
            loading = false
        }
    }
}
