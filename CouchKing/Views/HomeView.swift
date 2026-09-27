import SwiftUI

struct HomeView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [(String, [Meta])] = []
    @State private var top10: [Meta] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !session.signedIn {
                        GuestBanner()
                    }
                    let cw = session.continueWatching()
                    if !cw.isEmpty {
                        ContinueRow(items: cw)
                    }
                    if !top10.isEmpty {
                        Top10Row(metas: top10)
                    }
                    ForEach(rows, id: \.0) { row in
                        PosterRow(title: row.0, metas: row.1)
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.bg)
            .navigationTitle("👑 CouchKing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.profiles.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            session.currentProfile = ""
                            UserDefaults.standard.set("", forKey: "curProfile")
                        } label: {
                            Text(session.profiles.first { $0.id == session.currentProfile }?.avatar ?? "🍿")
                        }
                    }
                }
            }
            .task(id: session.currentProfile) {
                loading = true
                async let r = Catalog.homeRows(session: session)
                async let t = Catalog.top10(session: session)
                rows = await r; top10 = await t
                loading = false
            }
            .refreshable {
                async let r = Catalog.homeRows(session: session)
                async let t = Catalog.top10(session: session)
                rows = await r; top10 = await t
            }
        }
    }
}

struct PosterRow: View {
    let title: String
    let metas: [Meta]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(metas) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
    }
}

struct PosterCard: View {
    let meta: Meta
    @AppStorage("showTitles") private var showTitles = true   // per-profile default ON
    var body: some View {
        VStack(spacing: 4) {
            AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Theme.card.overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 108, height: 162)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if showTitles {
                Text(meta.name).font(.caption2).lineLimit(1).frame(width: 108)
                    .foregroundStyle(.primary)
            }
        }
        .titleMenu(meta)
    }
}

// Long-press title menu (Android titleMenu): Add/Remove Library · Mark watched/unwatched ·
// Clear progress — all mutate the synced state in place (tap the poster for Details).
struct TitleContextMenu: ViewModifier {
    @EnvironmentObject var session: Session
    let meta: Meta
    func body(content: Content) -> some View {
        content.contextMenu {
            Button(session.inLibrary(meta.id) ? "Remove from Library" : "Add to Library",
                   systemImage: session.inLibrary(meta.id) ? "minus.circle" : "plus.circle") {
                session.toggleLibrary(meta)
            }
            Button(session.isWatched(meta.id) ? "Mark unwatched" : "Mark watched",
                   systemImage: session.isWatched(meta.id) ? "eye.slash" : "checkmark.circle") {
                session.toggleWatched(meta)
            }
            Button("Clear progress", systemImage: "arrow.counterclockwise", role: .destructive) {
                session.clearProgress(meta)
            }
        }
    }
}
extension View { func titleMenu(_ meta: Meta) -> some View { modifier(TitleContextMenu(meta: meta)) } }

// Continue Watching — Android Home CW row: newest-first tiles with a resume progress bar.
struct ContinueRow: View {
    let items: [CWItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching").font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { item in
                        NavigationLink(value: item.meta) { CWCard(item: item) }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
    }
}

struct CWCard: View {
    let item: CWItem
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: URL(string: item.meta.poster ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Theme.card.overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
                .frame(width: 108, height: 162)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if item.progress > 0.01 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3)).frame(width: 96, height: 4)
                        Capsule().fill(Theme.accent).frame(width: 96 * item.progress, height: 4)
                    }
                    .padding(.bottom, 5)
                }
            }
            Text(item.meta.name).font(.caption2).lineLimit(1).frame(width: 108)
        }
        .titleMenu(item.meta)
    }
}

// Top 10 Today (Android addTop10Row): big ghost rank numeral behind each poster.
struct Top10Row: View {
    let metas: [Meta]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top 10 Today").font(.headline).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(Array(metas.enumerated()), id: \.element.id) { idx, m in
                        NavigationLink(value: m) { RankedCard(rank: idx + 1, meta: m) }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .navigationDestination(for: Meta.self) { DetailView(meta: $0) }
    }
}

struct RankedCard: View {
    let rank: Int
    let meta: Meta
    var body: some View {
        HStack(alignment: .bottom, spacing: -16) {
            Text("\(rank)")
                .font(.system(size: 104, weight: .heavy)).italic()
                .foregroundStyle(Theme.card)
                .frame(width: rank >= 10 ? 96 : 58, alignment: .trailing)
            AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Theme.card.overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 96, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .titleMenu(meta)
    }
}

struct GuestBanner: View {
    var body: some View {
        NavigationLink { SettingsView() } label: {
            HStack {
                Text("Sign in to sync your library, history and For You across devices")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }
}
