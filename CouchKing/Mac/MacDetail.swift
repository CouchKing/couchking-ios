#if os(macOS)
import SwiftUI

// Desktop details page (app.js detail() ~1122, style.css 101-150): a 380px backdrop at 35%
// opacity that fades out downward, "‹ Back", a 210×315 poster beside a 2rem title + meta line
// "year · runtime · ⭐ rating · genres", description, ALL-ghost buttons, cast chips, then
// streams inline immediately (movies) or the Episodes list (series → separate episode page).
struct MacDetail: View {
    @EnvironmentObject var session: Session
    @Environment(\.openURL) private var openURL
    let meta: Meta
    var autoplay = false            // hero Resume on a movie: play the top stream on arrival
    @State private var full: [String: Any] = [:]
    @State private var providers: TMDB.Providers?
    @State private var trailer: TrailerId?
    @State private var person: TMDB.Person?
    @State private var showPerson = false
    @State private var season = 1

    private var rich: Meta { Meta(full, type: meta.type) ?? meta }
    private var episodes: [Episode] { (full["videos"] as? [[String: Any]] ?? []).compactMap(Episode.init) }

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                DeskBackdrop(url: rich.background ?? meta.background ?? meta.poster, height: 380, opacity: 0.35)
                VStack(alignment: .leading, spacing: 0) {
                    DeskBack()
                    head.padding(.vertical, 16)
                    if meta.type == "movie" && session.canStream {
                        DeskRowLabel(text: "Streams")
                        StreamList(meta: meta, autoplay: autoplay)
                    }
                    if meta.type == "series" { episodeList }
                }
                .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
            }
        }
        .background(Desk.bg)
        .navigationBarBackButtonHidden(true)
        .task { await load() }
        .sheet(item: $trailer) { t in TrailerView(ytId: t.id).frame(minWidth: 900, minHeight: 540) }
        .navigationDestination(isPresented: $showPerson) {
            if let p = person { MacPerson(person: p) }
        }
    }

    // MARK: head (.d-head)
    private var head: some View {
        HStack(alignment: .top, spacing: 24) {
            AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Desk.card }
            .frame(width: 210, height: 315)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.67), radius: 15, y: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(meta.name).font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.53), radius: 5, y: 2)
                    .padding(.bottom, 6.4)
                Text(metaLine).font(.system(size: 16, weight: .bold)).foregroundStyle(Desk.muted)
                    .padding(.bottom, 11.2)
                Text(rich.description ?? "").font(.system(size: 16)).foregroundStyle(Desk.text2)
                    .lineSpacing(8.8).frame(maxWidth: 660, alignment: .leading)
                buttons.padding(.top, 16)
                castRow.padding(.vertical, 8)
                if !session.canStream { whereToWatch }
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = rich.releaseInfo { parts.append(y) }
        if let r = rich.runtime, !r.isEmpty { parts.append(r) }
        parts.append("⭐ " + (rich.imdbRating ?? "—"))
        if !rich.genres.isEmpty { parts.append(rich.genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// `.d-btns` — all ghost: 🎬 Trailer · + My List · Mark watched · 👍 · 👎 (no Download).
    private var buttons: some View {
        HStack(spacing: 9.6) {
            if let yt = ytId { Button("🎬 Trailer") { trailer = TrailerId(id: yt) } }
            Button(session.inLibrary(meta.id) ? "✓ In My List" : "+ My List") { session.toggleLibrary(meta) }
            Button(session.isWatched(meta.id) ? "✓ Watched" : "Mark watched") { session.toggleWatched(meta) }
            Button(session.rating(meta.id) == 1 ? "👍 Liked" : "👍") { session.setRating(meta.id, 1) }
            Button(session.rating(meta.id) == -1 ? "👎 Not for me" : "👎") { session.setRating(meta.id, -1) }
        }
        .buttonStyle(DeskButton(kind: .ghost))
    }

    /// `#d-cast` — up to 10 name chips (#2a2545, hover #3a3560) → person page.
    @ViewBuilder private var castRow: some View {
        let cast = Array((full["cast"] as? [String] ?? []).prefix(10))
        if !cast.isEmpty {
            FlowRow(spacing: 7.2) {
                ForEach(cast, id: \.self) { name in
                    Hovering { hover in
                        Button {
                            Task { if let p = await TMDB.people(name).first { person = p; showPerson = true } }
                        } label: {
                            Text(name).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Desk.muted)
                                .padding(.horizontal, 9.6).padding(.vertical, 1.9)
                                .background(hover ? Desk.chipHover : Desk.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// `#d-wtw` — accounts without a service: Stream / Rent / Buy provider chips "Name ↗".
    @ViewBuilder private var whereToWatch: some View {
        if let p = providers, !p.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                wtwKind("Where to watch")
                ForEach([("Stream", p.stream), ("Rent", p.rent), ("Buy", p.buy.filter { !p.rent.contains($0) })], id: \.0) { kind, names in
                    if !names.isEmpty {
                        wtwKind(kind)
                        FlowRow(spacing: 8) {
                            ForEach(names.prefix(6), id: \.self) { n in
                                Button { if let l = p.link, let u = URL(string: l) { openURL(u) } } label: {
                                    Text(n + " ↗").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 12.8).padding(.vertical, 8)
                                        .background(Desk.card, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
    private func wtwKind(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 13.6, weight: .heavy)).tracking(0.7).foregroundStyle(Desk.muted)
    }

    // MARK: episodes (.season-row + .ep rows)
    @ViewBuilder private var episodeList: some View {
        let seasons = Array(Set(episodes.map(\.season))).filter { $0 > 0 }.sorted()
        HStack(spacing: 12.8) {
            Text("Episodes").font(.system(size: 17.6, weight: .heavy)).foregroundStyle(.white)
            if seasons.count > 1 {
                Picker("", selection: $season) {
                    ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
        }
        .padding(.top, 19.2).padding(.bottom, 11.2)
        ForEach(episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }) { ep in
            MacEpisodeRow(meta: meta, ep: ep, episodes: episodes)
        }
    }

    private var ytId: String? {
        if let t = (full["trailers"] as? [[String: Any]])?.first?["source"] as? String { return t }
        return (full["trailerStreams"] as? [[String: Any]])?.first?["ytId"] as? String
    }

    private func load() async {
        full = await Catalog.fullMeta(session: session, type: meta.type, id: meta.id)
        if meta.type == "series", let v = full["videos"] as? [[String: Any]] {
            MetaCache.shared.put(meta.id, videos: v)
            // open on the season of the resume pointer (cwlast)
            if let last = (session.pstate()["cwlast"] as? [String: Any])?[meta.id] as? String,
               let s = Int(last.split(separator: ":").dropLast().last ?? "") { season = s }
            else if let f = episodes.map(\.season).filter({ $0 > 0 }).min() { season = f }
        }
        if !session.canStream {
            providers = await TMDB.providers(imdb: meta.id, kind: meta.type == "series" ? "tv" : "movie")
        }
    }
}

/// `.ep` — card row: 150×84 thumb (blur when unwatched + pref, green ✓ when seen, PURPLE progress),
/// "N. Name", date (· not aired), 2-line description, 👁/✓ toggle. Click → episode page.
struct MacEpisodeRow: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    let episodes: [Episode]
    @State private var open = false

    private var watched: Bool { session.isWatched(ep.id) }
    private var progress: Double {
        guard let s = (session.pstate()["positions"] as? [String: Any])?[ep.id] as? String else { return 0 }
        let p = s.split(separator: "|")
        guard p.count >= 2, let pos = Double(p[0]), let dur = Double(p[1]), dur > 0 else { return 0 }
        return min(1, pos / dur)
    }

    var body: some View {
        let blur = !watched && session.pref("blurUnwatched", false)
        Hovering { hover in
            HStack(spacing: 16) {
                ZStack {
                    AsyncImage(url: URL(string: ep.thumb ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.black }
                    .frame(width: 150, height: 84)
                    .blur(radius: blur ? 13 : 0).saturation(blur ? 0.85 : 1)
                    .clipped()
                    if watched {
                        VStack { HStack { Spacer()
                            Text("✓").font(.system(size: 12.8, weight: .bold)).foregroundStyle(Desk.seenGreen)
                                .frame(width: 24, height: 24).background(Desk.bg.opacity(0xD9 / 255.0), in: Circle())
                        }; Spacer() }.padding(4.8)
                    }
                    if progress > 0.01 {
                        VStack { Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.6))
                                Rectangle().fill(Desk.accent).frame(width: 150 * progress)
                            }.frame(height: 4)
                        }
                    }
                }
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(ep.episode). \(ep.name)").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .padding(.bottom, 2.4)
                    Text(String((ep.released ?? "").prefix(10)) + (ep.unaired ? " · not aired" : ""))
                        .font(.system(size: 13.6)).foregroundStyle(Desk.muted)
                    if !blur, let d = ep.overview, !d.isEmpty {
                        Text(d).font(.system(size: 13.3)).foregroundStyle(Desk.epDesc).lineLimit(2).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Hovering { eyeHover in
                    Button { session.toggleEpisodeWatched(ep.id) } label: {
                        Text(watched ? "✓" : "👁").font(.system(size: 16)).foregroundStyle(.white)
                            .padding(.horizontal, 11.2).padding(.vertical, 8)
                            .background(eyeHover ? Desk.accent : Desk.card2, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13.6).padding(.vertical, 10.4)
            .background(hover && !ep.unaired ? Desk.card2 : Desk.card, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture { if !ep.unaired { open = true } }
        }
        .opacity(ep.unaired ? 0.45 : 1)
        .padding(.bottom, 8)
        .navigationDestination(isPresented: $open) { MacEpisodePage(meta: meta, ep: ep, episodes: episodes) }
    }
}

/// Episode page (app.js episodePage() ~1334): backdrop, ‹ Back, logo (or name), facts
/// "year  ·  S01E02  ·  date  ·  name", "Resume from N%", description, Mark watched, Streams.
struct MacEpisodePage: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    let episodes: [Episode]
    var autoplay = false

    private var resumePct: Int? {
        guard let s = (session.pstate()["positions"] as? [String: Any])?[ep.id] as? String else { return nil }
        let p = s.split(separator: "|")
        guard p.count >= 2, let pos = Double(p[0]), let dur = Double(p[1]), dur > 0, pos > 60_000 else { return nil }
        return Int(pos / dur * 100)
    }

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                DeskBackdrop(url: meta.background ?? ep.thumb ?? meta.poster, height: 380, opacity: 0.35)
                VStack(alignment: .leading, spacing: 0) {
                    DeskBack()
                    VStack(alignment: .leading, spacing: 0) {
                        if let logo = meta.logo, let u = URL(string: logo) {
                            AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fit) }
                                placeholder: { Text(meta.name).font(.system(size: 32, weight: .bold)) }
                                .frame(maxWidth: 380, maxHeight: 72, alignment: .leading)
                        } else {
                            Text(meta.name).font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                        }
                        Text(facts).font(.system(size: 14.7, weight: .bold)).foregroundStyle(Desk.muted)
                            .padding(.vertical, 4.8)
                        if let pct = resumePct {
                            Text("Resume from \(pct)%").font(.system(size: 14.4, weight: .bold)).foregroundStyle(Desk.accent)
                        }
                        if let d = ep.overview, !d.isEmpty {
                            Text(d).font(.system(size: 16)).foregroundStyle(Desk.text2).lineSpacing(8.8)
                                .frame(maxWidth: 660, alignment: .leading).padding(.vertical, 8)
                        }
                        Button(session.isWatched(ep.id) ? "✓ Watched" : "Mark watched") { session.toggleEpisodeWatched(ep.id) }
                            .buttonStyle(DeskButton(kind: .ghost, small: true))
                        if session.canStream {
                            DeskRowLabel(text: "Streams")
                            StreamList(meta: meta, season: ep.season, episode: ep.episode, episodes: episodes, autoplay: autoplay)
                                .frame(maxWidth: 760)
                        }
                    }
                    .padding(.top, 12.8)
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
            }
        }
        .background(Desk.bg)
        .navigationBarBackButtonHidden(true)
    }

    private var facts: String {
        var parts: [String] = []
        if let y = meta.releaseInfo { parts.append(String(y.prefix(4))) }
        parts.append(String(format: "S%02dE%02d", ep.season, ep.episode))
        if let r = ep.released { parts.append(String(r.prefix(10))) }
        parts.append(ep.name)
        return parts.joined(separator: "  ·  ")
    }
}

/// Person page: ‹ Back, 88px circle photo + name + role, then Shows / Movies strips (14 each).
struct MacPerson: View {
    let person: TMDB.Person
    @State private var credits: [Meta] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DeskBack()
                HStack(spacing: 17.6) {
                    AsyncImage(url: URL(string: person.profile ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Desk.card.overlay(Text("👤").font(.system(size: 32))) }
                    .frame(width: 88, height: 88).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        Text(person.known.isEmpty ? "Actor" : person.known).foregroundStyle(Desk.muted)
                    }
                }
                .padding(.vertical, 16)
                ForEach([("Shows", "series"), ("Movies", "movie")], id: \.0) { label, type in
                    let list = Array(credits.filter { $0.type == type }.prefix(14))
                    if !list.isEmpty {
                        DeskRowLabel(text: label)
                        DeskStrip { ForEach(list) { m in NavigationLink(value: m) { DeskPoster(meta: m) }.buttonStyle(.plain) } }
                    }
                }
            }
            .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
        }
        .background(Desk.bg)
        .navigationBarBackButtonHidden(true)
        .task { credits = await TMDB.filmography(person.id) }
    }
}

/// `#detail-backdrop`: absolute top band, cover at center 25%, faded opacity, masked to
/// transparent toward the bottom.
struct DeskBackdrop: View {
    let url: String?
    let height: CGFloat
    let opacity: Double
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color.clear }
        .frame(maxWidth: .infinity).frame(height: height).clipped()
        .opacity(opacity)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

/// Wrapping row (chip lists) — macOS 13 Layout.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
#endif
