import SwiftUI

// Series episodes — Android parity: season picker, episode rows with thumbnails
// (blurred when unwatched + pref on), per-episode watched eyes, tap = stream sheet.
struct Episode: Identifiable {
    let id: String        // "tt123:1:2"
    let season: Int, episode: Int
    let name: String, thumb: String?, released: String?
    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        season = o["season"] as? Int ?? Int(o["season"] as? String ?? "") ?? 0
        episode = o["episode"] as? Int ?? o["number"] as? Int ?? Int(o["episode"] as? String ?? "") ?? 0
        name = o["name"] as? String ?? o["title"] as? String ?? "Episode"
        thumb = o["thumbnail"] as? String
        released = o["released"] as? String
    }
}

struct EpisodesView: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let videos: [[String: Any]]
    @State private var season = 1
    @State private var pick: Episode?

    private var episodes: [Episode] {
        videos.compactMap(Episode.init).filter { $0.season == season }
            .sorted { $0.episode < $1.episode }
    }
    private var seasons: [Int] {
        Array(Set(videos.compactMap(Episode.init).map(\.season))).filter { $0 > 0 }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(seasons, id: \.self) { s in
                            Button("Season \(s)") { season = s }
                                .buttonStyle(.bordered)
                                .tint(s == season ? Theme.accent : .gray)
                        }
                    }
                }
            }
            ForEach(episodes) { ep in
                EpisodeRow(meta: meta, ep: ep) { pick = ep }
            }
        }
        .onAppear { if let f = seasons.first { season = f } }
        .sheet(item: $pick) { ep in
            StreamSheet(meta: meta, season: ep.season, episode: ep.episode)
                .presentationDetents([.medium, .large])
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    let onPlay: () -> Void

    private var watched: Bool {
        ((session.pstate()["watchedIds"] as? [String]) ?? []).contains(ep.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                AsyncImage(url: URL(string: ep.thumb ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Theme.card }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .blur(radius: (!watched && session.pref("blurUnwatched", false)) ? 8 : 0)
                .clipped()
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("E\(ep.episode) · \(ep.name)").font(.subheadline).lineLimit(2)
                if let r = ep.released {
                    Text(String(r.prefix(10))).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                toggleEp()
            } label: {
                Image(systemName: watched ? "eye.fill" : "eye")
                    .foregroundStyle(watched ? Theme.accent : .secondary)
            }.buttonStyle(.plain)
        }
    }

    private func toggleEp() {
        var ps = session.pstate()
        var ids = ps["watchedIds"] as? [String] ?? []
        var stamps = ps[watched ? "removedTs" : "addedTs"] as? [String: Any] ?? [:]
        if watched { ids.removeAll { $0 == ep.id } } else { ids.append(ep.id) }
        stamps["wt:" + ep.id] = Int(Date().timeIntervalSince1970 * 1000)
        ps["watchedIds"] = ids
        ps[watched ? "removedTs" : "addedTs"] = stamps
        session.setPstate(ps)
    }
}

// Shared stream picker for movies + episodes — CouchKing-styled rows, plays on tap.
struct StreamSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let meta: Meta
    var season: Int? = nil
    var episode: Int? = nil
    @State private var streams: [[String: Any]] = []
    @State private var loading = true
    @State private var play: PlayRequest?

    var body: some View {
        NavigationStack {
            List {
                // expiry banner WHERE the streams would be — browsing never blocks, only
                // play time shows it (Android expiryBanner parity, AJ Sep 18 rule)
                if session.isExpired {
                    VStack(alignment: .center, spacing: 6) {
                        Text("⛔").font(.system(size: 44))
                        Text("Subscription expired").font(.headline)
                        Text("Renew your plan to keep watching.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowBackground(Color.clear)
                }
                else if loading { ProgressView() }
                else if streams.isEmpty { Text("No streams right now — try again in a minute.") }
                ForEach(Array(streams.prefix(10).enumerated()), id: \.offset) { _, s in
                    Button {
                        if let u = s["url"] as? String, let url = URL(string: u) {
                            play = PlayRequest(url: url, meta: meta, season: season, episode: episode)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s["name"] as? String ?? "Stream").font(.subheadline.bold())
                            Text(s["title"] as? String ?? s["description"] as? String ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle(season != nil ? "S\(season!)E\(episode!)" : meta.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
        .fullScreenCover(item: $play) { req in PlayerView(request: req) }
    }

    private func load() async {
        defer { loading = false }
        guard !session.isExpired, let addon = session.addons.first else { return }
        let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let sid = season != nil ? "\(meta.id):\(season!):\(episode!)" : meta.id
        let type = season != nil ? "series" : "movie"
        if let r = try? await API.json("/stream/\(type)/\(sid).json?u=\(u)", base: addon.url) {
            streams = r["streams"] as? [[String: Any]] ?? []
        }
    }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let meta: Meta
    let season: Int?
    let episode: Int?
    // "Are you still watching?" chain: consecutive fully-input-less auto-advanced
    // episodes so far (rides along because each auto-advance is a fresh PlayerView)
    var idleEps: Int = 0
}
