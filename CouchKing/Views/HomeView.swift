import SwiftUI

struct HomeView: View {
    @EnvironmentObject var session: Session
    @State private var rows: [(String, [Meta])] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !session.signedIn {
                        GuestBanner()
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
                rows = await Catalog.homeRows(session: session)
                loading = false
            }
            .refreshable { rows = await Catalog.homeRows(session: session) }
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
