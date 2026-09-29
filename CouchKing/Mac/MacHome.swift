#if os(macOS)
import SwiftUI

// Desktop Home (app.js home() ~1010): static hero, then — in pre-placed slots so async fills
// keep this order — Continue Watching · Top 10 Today · For You — Movies · For You — Series ·
// the person's shelves in their synced order. Empty rows are dropped. Every 60s the hero,
// Continue row and badges repaint in place.
struct MacHome: View {
    @EnvironmentObject var session: Session
    @State private var hero: HeroItem?
    @State private var cw: [CWItem] = []
    @State private var top10: [Meta] = []
    @State private var rows: [(String, [Meta])] = []
    @State private var loadGen = 0
    @State private var resume: CWItem?

    struct HeroItem { let meta: Meta; let background: String; let sub: String; let cw: CWItem? }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let hero { heroView(hero).padding(.bottom, 9.6) }
                if session.hasAddon && !cw.isEmpty {
                    DeskRowLabel(text: "Continue Watching")
                    DeskStrip {
                        ForEach(cw) { item in
                            NavigationLink(value: item.meta) {
                                DeskPoster(meta: item.meta, progress: item.progress, newEps: item.newEps,
                                           episodeChip: chip(item.resumeKey), continueTile: true,
                                           onRemove: { session.clearProgress(item.meta) })
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                session.dismissNewEpsBadge(item.meta.id, latestAir: item.latestAir)
                            })
                        }
                    }
                }
                if !top10.isEmpty {
                    DeskRowLabel(text: "Top 10 Today")
                    DeskStrip {
                        ForEach(Array(top10.enumerated()), id: \.element.id) { i, m in
                            NavigationLink(value: m) { DeskTop10Tile(rank: i + 1, meta: m) }.buttonStyle(.plain)
                        }
                    }
                }
                ForEach(rows, id: \.0) { row in
                    DeskRowLabel(text: row.0)
                    DeskStrip {
                        ForEach(row.1) { m in
                            NavigationLink(value: m) { DeskPoster(meta: m) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
        }
        .background(Desk.bg)
        .task(id: "\(session.currentProfile)|\(session.homeStale)|\(session.addons.first?.url ?? "")") { await load() }
        // quiet 60s sync: repaint only the hero + Continue row + badges
        .onReceive(session.objectWillChange) { _ in
            Task { cw = await session.continueWatchingOrdered(); await paintHero() }
        }
        .sheet(item: $resume) { item in
            let p = item.resumeKey.split(separator: ":")
            StreamSheet(meta: item.meta, season: p.count >= 3 ? Int(p[p.count - 2]) : nil,
                        episode: p.count >= 3 ? Int(p[p.count - 1]) : nil, autoplay: true)
                .ckDetents()
        }
    }

    /// "S2 · E4" from a cwlast key "tt…:2:4".
    private func chip(_ key: String) -> String? {
        let p = key.split(separator: ":")
        guard p.count >= 3 else { return nil }
        return "S\(p[p.count - 2]) · E\(p[p.count - 1])"
    }

    /// `#hero`: min-height 290, r16, backdrop at center 20%, bottom + left dark fades, text
    /// bottom-left (h2 2rem/900 with shadow, sub #d8d5ea/700), ▶ Resume|Watch + More info.
    private func heroView(_ h: HeroItem) -> some View {
        NavigationLink(value: h.meta) {
            ZStack(alignment: .bottomLeading) {
                Desk.card
                AsyncImage(url: URL(string: h.background)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Desk.card }
                .frame(maxWidth: .infinity, minHeight: 290, maxHeight: 290, alignment: .init(horizontal: .center, vertical: .top))
                .clipped()
                LinearGradient(stops: [.init(color: Desk.bg.opacity(0), location: 0.2),
                                       .init(color: Desk.bg.opacity(0xEE / 255.0), location: 0.92)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [.init(color: Desk.bg.opacity(0xCC / 255.0), location: 0),
                                       .init(color: Desk.bg.opacity(0), location: 0.45)],
                               startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: 0) {
                    Text(h.meta.name).font(.system(size: 32, weight: .black)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.67), radius: 6, y: 2)
                    Text(h.sub).font(.system(size: 16, weight: .bold)).foregroundStyle(Desk.text2)
                        .padding(.top, 5.6).padding(.bottom, 12.8)
                    HStack(spacing: 9.6) {
                        if session.hasAddon {
                            Button(h.cw != nil ? "▶ Resume" : "▶ Watch") {
                                if let c = h.cw { resume = c }
                                else { resume = CWItem(meta: h.meta, progress: 0, resumeKey: h.meta.id) }
                            }
                            .buttonStyle(DeskButton(kind: .primary))
                        }
                        NavigationLink(value: h.meta) { Text("More info") }
                            .buttonStyle(DeskButton(kind: .ghost))
                    }
                }
                .padding(.horizontal, 25.6).padding(.vertical, 22.4)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(minHeight: 290)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The hero is ONE static item: Continue Watching #1 (its Cinemeta backdrop), else TMDB
    /// trending TV this week #1. No rotation.
    private func paintHero() async {
        if let first = cw.first {
            if hero?.meta.id == first.meta.id { return }
            let full = await Catalog.fullMeta(session: session, type: first.meta.type, id: first.meta.id)
            guard let bg = full["background"] as? String, !bg.isEmpty else { return }
            var sub = "Continue watching"
            if let c = chip(first.resumeKey) { sub += " · " + c }
            hero = HeroItem(meta: first.meta, background: bg, sub: sub, cw: first)
        } else if hero == nil || hero?.cw != nil {
            if let t = await TMDB.trending(kind: "tv").first(where: { $0.background != nil }) {
                hero = HeroItem(meta: t, background: t.background ?? "", sub: "Trending this week", cw: nil)
            }
        }
    }

    private func load() async {
        loadGen += 1
        let gen = loadGen
        cw = session.hasAddon ? await session.continueWatchingOrdered() : []
        await paintHero()
        // Top 10 Today: TMDB trending movie + tv of the DAY, interleaved, never shuffled
        async let tm = TMDB.trendingDay(kind: "movie")
        async let tt = TMDB.trendingDay(kind: "tv")
        let t10 = Catalog.interleave(await tm, await tt)
        guard gen == loadGen else { return }
        top10 = t10
        var fresh: [(String, [Meta])] = []
        rows = []
        if session.hasAddon {
            for (title, cat) in Catalog.homeLineup(session: session) {
                var metas = await Catalog.shelf(session: session, cat)
                guard gen == loadGen else { return }
                if metas.isEmpty { continue }
                if !cat.isForYou && !cat.isOrdered && cat.curated.isEmpty {
                    metas = Catalog.mix(metas, session: session, salt: cat.id)
                }
                fresh.append((title == "For You — Shows" ? "For You — Series" : title, metas))
                rows = fresh
            }
        } else {
            // guests: no For You rows (desktop), discovery shelves only
            for (title, type, path) in Catalog.guestRows {
                let metas = await Catalog.guestRow(type, path)
                guard gen == loadGen else { return }
                if metas.isEmpty { continue }
                fresh.append((title, Catalog.mix(metas, session: session, salt: title)))
                rows = fresh
            }
            for cat in session.enabledShelves() where !cat.curated.isEmpty {
                let metas = await Catalog.shelf(session: session, cat)
                guard gen == loadGen else { return }
                if !metas.isEmpty { fresh.append((cat.name, metas)); rows = fresh }
            }
        }
    }
}
#endif
