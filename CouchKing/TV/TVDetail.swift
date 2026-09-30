#if os(tvOS)
import SwiftUI

// Details page (showDetailTv ~5227 / tvPageShell ~5152): full-screen backdrop, left gradient
// #F70C0B14 → #D90C0B14 → #330C0B14 → clear, 260dp bottom scrim; a 480dp info column on top and a
// bottom block (stream strip for movies, the continuous episode strip for series). No on-screen
// back button — Menu walks back.
struct TVDetail: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    @State private var full: [String: Any] = [:]
    @State private var providers: TMDB.Providers?
    @State private var actionLabel = ""
    @State private var focusedEp: Episode?

    private var rich: Meta { Meta(full, type: meta.type) ?? meta }
    private var episodes: [Episode] {
        (full["videos"] as? [[String: Any]] ?? []).compactMap(Episode.init).filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVPageShell(backdrop: rich.background ?? meta.background ?? meta.poster)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if meta.type == "series" { seriesHeader } else { movieHeader }
                        castStrip.padding(.top, TV.dp(10))
                        actions.padding(.top, TV.dp(12))
                        if !session.canStream { whereToWatch.padding(.top, TV.dp(12)) }
                    }
                    .frame(width: TV.dp(480), alignment: .leading)
                    if meta.type == "movie", session.canStream {
                        StreamList(meta: meta).padding(.top, TV.dp(16))
                    }
                    if meta.type == "series", !episodes.isEmpty {
                        TVEpisodeStrip(meta: meta, episodes: episodes, focused: $focusedEp)
                            .padding(.top, TV.dp(16))
                    }
                }
                .padding(.leading, TV.dp(30)).padding(.top, TV.dp(18)).padding(.trailing, TV.dp(16)).padding(.bottom, TV.dp(12))
            }
        }
        .ignoresSafeArea()
        .task { await load() }
    }

    // MARK: headers
    @ViewBuilder private func logoOrName(height: CGFloat, top: CGFloat) -> some View {
        if let logo = rich.logo, let u = URL(string: logo) {
            AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fit) }
                placeholder: { Text(meta.name).font(.system(size: TV.sp(30), weight: .bold)) }
                .frame(maxWidth: TV.dp(420), maxHeight: TV.dp(height), alignment: .leading)
                .padding(.top, TV.dp(top))
        } else {
            Text(meta.name).font(.system(size: TV.sp(30), weight: .bold)).foregroundStyle(.white)
                .lineLimit(2).padding(.top, TV.dp(top))
        }
    }

    /// Movie (tvInfoBlock ~5185): logo 70dp, facts "runtime   year   ★ rating" 13.5sp, first 4
    /// genre chips → Discover, description 13sp #DDDAEA max 11 lines.
    private var movieHeader: some View {
        VStack(alignment: .leading, spacing: TV.dp(6)) {
            logoOrName(height: 70, top: 16)
            Text([rich.runtime, rich.releaseInfo, rich.imdbRating.map { "★ " + $0 }].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: "   "))
                .font(.system(size: TV.sp(13.5))).foregroundStyle(.white)
            if !rich.genres.isEmpty {
                HStack(spacing: TV.dp(8)) {
                    ForEach(rich.genres.prefix(4), id: \.self) { g in
                        NavigationLink { BrowseView(initialType: "movie", initialGenre: g) } label: {
                            TVPersonChip(text: g, size: 12)
                        }
                        .buttonStyle(TVRingButton(radius: TV.dp(16)))
                    }
                }
                .focusSection()
            }
            if let d = rich.description, !d.isEmpty {
                Text(d).font(.system(size: TV.sp(13))).foregroundStyle(TV.detailDesc)
                    .lineLimit(11).lineSpacing(TV.sp(13) * 0.2)
            }
        }
    }

    /// Series: logo 74dp, then "Name (year)   ★ rating" 13sp #A9A5C0 — no show description (the
    /// focused episode's text shows in the strip instead).
    private var seriesHeader: some View {
        VStack(alignment: .leading, spacing: TV.dp(6)) {
            logoOrName(height: 74, top: 14)
            Text(meta.name + (rich.releaseInfo.map { " (\($0))" } ?? "") + (rich.imdbRating.map { "   ★ " + $0 } ?? ""))
                .font(.system(size: TV.sp(13))).foregroundStyle(TV.dim)
        }
    }

    /// Cast: up to 8 person chips (13.5sp white, #2C2649 r16dp) → person page.
    @ViewBuilder private var castStrip: some View {
        let cast = Array((full["cast"] as? [String] ?? []).prefix(8))
        if !cast.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TV.dp(8)) {
                    ForEach(cast, id: \.self) { name in
                        TVCastChip(name: name)
                    }
                }
                .padding(.vertical, TV.dp(4))
            }
            .focusSection()
        }
    }

    /// Round 54dp icon actions (selBg #2C2649) with a live label beside them naming the focused one:
    /// [Trailer — hidden on Apple TV, no web player] · Library · Watched (movies) · 👍 · 👎.
    private var actions: some View {
        HStack(spacing: TV.dp(12)) {
            TVActionButton(icon: session.inLibrary(meta.id) ? "minus" : "plus",
                           label: session.inLibrary(meta.id) ? "Remove from Library" : "Add to Library",
                           current: $actionLabel) { session.toggleLibrary(meta) }
            if meta.type == "movie" {
                TVActionButton(icon: session.isWatched(meta.id) ? "eye.slash" : "eye",
                               label: session.isWatched(meta.id) ? "Mark as Unwatched" : "Mark as Watched",
                               current: $actionLabel) { session.toggleWatched(meta) }
            }
            TVActionButton(icon: session.rating(meta.id) == 1 ? "hand.thumbsup.fill" : "hand.thumbsup",
                           label: session.rating(meta.id) == 1 ? "Liked — For You shows more like this" : "Like",
                           current: $actionLabel) { session.setRating(meta.id, 1) }
            TVActionButton(icon: session.rating(meta.id) == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                           label: session.rating(meta.id) == -1 ? "Not for me — For You shows less like this" : "Not for me",
                           current: $actionLabel) { session.setRating(meta.id, -1) }
            Text(actionLabel).font(.system(size: TV.sp(12.5))).foregroundStyle(TV.dim)
                .padding(.leading, TV.dp(8)).lineLimit(1)
        }
        .focusSection()
    }

    /// Where to watch (no addon): informational chips only — Apple TV has no browser.
    @ViewBuilder private var whereToWatch: some View {
        if let p = providers, !p.isEmpty {
            VStack(alignment: .leading, spacing: TV.dp(8)) {
                Text("▶ Where to watch").font(.system(size: TV.sp(16), weight: .bold))
                let chips = providerChips(p)
                HStack(spacing: TV.dp(8)) {
                    ForEach(chips, id: \.0) { label, accent in
                        Text(label).font(.system(size: TV.sp(13.5), weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, TV.dp(14)).padding(.vertical, TV.dp(9))
                            .background(accent ? TV.accent : TV.chip, in: RoundedRectangle(cornerRadius: TV.dp(18)))
                    }
                }
            }
        } else if providers != nil, meta.type == "movie",
                  (Int((rich.releaseInfo ?? "").prefix(4)) ?? 0) >= Calendar.current.component(.year, from: Date()) - 1 {
            Text("🎬 In theaters now — home release hasn't happened yet")
                .font(.system(size: TV.sp(13.5), weight: .bold)).foregroundStyle(TV.gold)
        }
    }

    private func providerChips(_ p: TMDB.Providers) -> [(String, Bool)] {
        let rent = Array(p.rent.prefix(4))
        var out: [(String, Bool)] = p.stream.prefix(4).map { ($0, true) }
        out += rent.map { ("Rent · " + $0, false) }
        out += p.buy.filter { !rent.contains($0) }.prefix(4).map { ("Buy · " + $0, false) }
        return out
    }

    private func load() async {
        full = await Catalog.fullMeta(session: session, type: meta.type, id: meta.id)
        if meta.type == "series", let v = full["videos"] as? [[String: Any]] { MetaCache.shared.put(meta.id, videos: v) }
        if !session.canStream {
            providers = await TMDB.providers(imdb: meta.id, kind: meta.type == "series" ? "tv" : "movie") ?? TMDB.Providers()
        }
    }
}

/// Backdrop + the detail scrims (shared by Details and the Episode page).
struct TVPageShell: View {
    let backdrop: String?
    var body: some View {
        ZStack {
            TV.bg
            AsyncImage(url: URL(string: backdrop ?? "")) { img in img.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Color.clear }
                .frame(width: 1920, height: 1080).clipped()
            LinearGradient(colors: [TV.argb(0xF70C0B14), TV.argb(0xD90C0B14), TV.argb(0x330C0B14), .clear],
                           startPoint: .leading, endPoint: .trailing)
            VStack { Spacer()
                LinearGradient(colors: [TV.bg, TV.argb(0xCC0C0B14), .clear], startPoint: .bottom, endPoint: .top)
                    .frame(height: TV.dp(260))
            }
        }
        .ignoresSafeArea()
    }
}

struct TVPersonChip: View {
    let text: String
    var size: CGFloat = 13.5
    var body: some View {
        Text(text).font(.system(size: TV.sp(size))).foregroundStyle(.white)
            .padding(.horizontal, TV.dp(13)).padding(.vertical, TV.dp(8))
            .background(TV.chip, in: RoundedRectangle(cornerRadius: TV.dp(16)))
    }
}

struct TVCastChip: View {
    let name: String
    @State private var person: TMDB.Person?
    @State private var open = false
    var body: some View {
        Button { Task { if let p = await TMDB.people(name).first { person = p; open = true } } } label: {
            TVPersonChip(text: name)
        }
        .buttonStyle(TVRingButton(radius: TV.dp(16)))
        .navigationDestination(isPresented: $open) { if let p = person { TVPerson(person: p) } }
    }
}

/// 54dp circle icon button (selBg #2C2649, r26) that reports its label when focused.
struct TVActionButton: View {
    let icon: String
    let label: String
    @Binding var current: String
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: TV.dp(22), weight: .semibold)).foregroundStyle(.white)
                .frame(width: TV.dp(54), height: TV.dp(54))
                .background(TV.chip, in: Circle())
        }
        .buttonStyle(TVRingButton(radius: TV.dp(27)))
        .focused($focused)
        .onChange(of: focused) { f in if f { current = label } else if current == label { current = "" } }
        .onChange(of: label) { l in if focused { current = l } }
    }
}

// Episode strip (buildTvEpisodeStrip ~5367): ONE continuous strip across all seasons. Season chips
// (accent = current, follow focus) jump to a season's first card; hover text shows the focused
// episode "S1 E3 · Name" + 3-line description; 2×104dp #4A4470 dividers between seasons; cards
// 206dp with a 202×114dp thumb (E03 badge, gold watched eye, hourglass when unaired, accent bar),
// "N. Name" 13.5sp medium, date 10.5sp. Focus scale 1.06/110ms. Initial focus: the cwlast episode,
// else the first unwatched. Select → episode page.
struct TVEpisodeStrip: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let episodes: [Episode]
    @Binding var focused: Episode?
    @Namespace private var ns
    @State private var jump: String?

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    private var startId: String {
        if let last = (session.pstate()["cwlast"] as? [String: Any])?[meta.id] as? String,
           episodes.contains(where: { $0.id == last }) { return last }
        return episodes.first { !session.isWatched($0.id) && !$0.unaired }?.id ?? episodes.first?.id ?? ""
    }

    var body: some View {
        let cur = focused ?? episodes.first { $0.id == startId }
        VStack(alignment: .leading, spacing: TV.dp(8)) {
            if seasons.count > 1 {
                HStack(spacing: TV.dp(7)) {
                    ForEach(seasons, id: \.self) { s in
                        Button { jump = episodes.first { $0.season == s }?.id } label: {
                            Text("Season \(s)").font(.system(size: TV.sp(13), weight: cur?.season == s ? .bold : .regular))
                                .foregroundStyle(cur?.season == s ? .white : TV.dim)
                                .padding(.horizontal, TV.dp(12)).padding(.vertical, TV.dp(6))
                                .background(cur?.season == s ? TV.accent : TV.chip, in: RoundedRectangle(cornerRadius: TV.dp(14)))
                        }
                        .buttonStyle(TVRingButton(radius: TV.dp(14)))
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
            }
            if let e = cur {
                Text("S\(e.season) E\(e.episode) · \(e.name)").font(.system(size: TV.sp(14.5), weight: .bold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(e.overview ?? " ").font(.system(size: TV.sp(13.5))).foregroundStyle(TV.epHoverDesc)
                    .lineLimit(3).frame(width: TV.dp(560), alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { i, ep in
                            if i > 0 && episodes[i - 1].season != ep.season {
                                Rectangle().fill(TV.rgb(0x4A4470)).frame(width: TV.dp(2), height: TV.dp(104))
                                    .padding(.leading, TV.dp(10)).padding(.top, TV.dp(6)).padding(.trailing, TV.dp(12))
                            }
                            TVEpisodeCard(meta: meta, ep: ep, episodes: episodes) { focused = ep }
                                .prefersDefaultFocus(ep.id == startId, in: ns)
                                .id(ep.id)
                        }
                    }
                    .padding(.vertical, TV.dp(10)).padding(.horizontal, TV.dp(6))
                }
                .focusScope(ns)
                .onChange(of: jump) { id in if let id { withAnimation { proxy.scrollTo(id, anchor: .leading) }; jump = nil } }
                .onAppear { proxy.scrollTo(startId, anchor: .leading) }
            }
            .focusSection()
        }
    }
}

struct TVEpisodeCard: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    let episodes: [Episode]
    let onFocus: () -> Void
    @FocusState private var isFocused: Bool
    @State private var open = false

    private var watched: Bool { session.isWatched(ep.id) }
    private var progress: Double {
        if watched { return 1 }
        guard let s = (session.pstate()["positions"] as? [String: Any])?[ep.id] as? String else { return 0 }
        let p = s.split(separator: "|")
        guard p.count >= 2, let pos = Double(p[0]), let dur = Double(p[1]), dur > 0, pos > 1000 else { return 0 }
        return min(1, pos / dur)
    }

    var body: some View {
        let blur = !watched && session.pref("blurUnwatched", false)
        Button { if !ep.unaired { open = true } } label: {
            VStack(alignment: .leading, spacing: TV.dp(3)) {
                ZStack {
                    AsyncImage(url: URL(string: ep.thumb ?? "")) { img in img.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { TV.card }
                        .frame(width: TV.dp(202), height: TV.dp(114))
                        .blur(radius: blur ? 16 : 0)
                        .clipped()
                    VStack {
                        HStack(alignment: .top) {
                            if watched {
                                Image(systemName: "eye.fill").font(.system(size: TV.dp(12))).foregroundStyle(TV.gold)
                                    .frame(width: TV.dp(26), height: TV.dp(26)).background(TV.argb(0x99000000), in: Circle())
                            }
                            Spacer()
                            Text(String(format: "E%02d", ep.episode)).font(.system(size: TV.sp(12), weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, TV.dp(6)).padding(.vertical, TV.dp(1))
                                .background(TV.argb(0x99000000), in: RoundedRectangle(cornerRadius: TV.dp(6)))
                        }
                        Spacer()
                    }
                    .padding(TV.dp(5))
                    if ep.unaired {
                        Image(systemName: "hourglass").font(.system(size: TV.dp(16))).foregroundStyle(.white)
                            .frame(width: TV.dp(38), height: TV.dp(38)).background(TV.argb(0xB3000000), in: Circle())
                    }
                    if progress > 0 {
                        VStack { Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle().fill(TV.argb(0x66000000))
                                Rectangle().fill(TV.accent).frame(width: TV.dp(202) * progress)
                            }
                            .frame(height: TV.dp(4))
                        }
                    }
                }
                .frame(width: TV.dp(202), height: TV.dp(114))
                .background(TV.card)
                .clipShape(RoundedRectangle(cornerRadius: TV.dp(7)))
                Text("\(ep.episode). \(ep.name)").font(.system(size: TV.sp(13.5), weight: .medium))
                    .foregroundStyle(watched ? TV.dim : .white).lineLimit(1)
                Text(ep.airDate).font(.system(size: TV.sp(10.5))).foregroundStyle(ep.unaired ? TV.gold : TV.dim)
            }
            .frame(width: TV.dp(206), alignment: .leading)
            .opacity(ep.unaired ? 0.55 : 1)
        }
        .buttonStyle(TVScaleButton(scale: 1.06, duration: 0.11))
        .padding(.horizontal, TV.dp(5)).padding(.vertical, TV.dp(2))
        .focused($isFocused)
        .onChange(of: isFocused) { f in if f { onFocus() } }
        .contextMenu {
            Button(watched ? "Mark as Unwatched" : "Mark as Watched") { session.toggleEpisodeWatched(ep.id) }
            Button("Clear Episode Progress") { clearEpisodeProgress() }
        }
        .navigationDestination(isPresented: $open) { TVEpisodePage(meta: meta, ep: ep, episodes: episodes) }
    }

    private func clearEpisodeProgress() {
        var ps = session.pstate()
        var positions = ps["positions"] as? [String: Any] ?? [:]
        positions.removeValue(forKey: ep.id)
        ps["positions"] = positions
        var removed = ps["removedTs"] as? [String: Any] ?? [:]
        removed["pos:" + ep.id] = Int(Date().timeIntervalSince1970 * 1000)
        ps["removedTs"] = removed
        session.setPstate(ps)
    }
}

/// Episode page (showEpisodeDetailTv ~5613): same shell; facts "year  ·  S01E03  ·  released  ·
/// name", description, "Resume from N%" (>60s), then the stream strip.
struct TVEpisodePage: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let ep: Episode
    let episodes: [Episode]
    var body: some View {
        ZStack(alignment: .topLeading) {
            TVPageShell(backdrop: meta.background ?? ep.thumb ?? meta.poster)
            VStack(alignment: .leading, spacing: TV.dp(6)) {
                Text(ep.name).font(.system(size: TV.sp(30), weight: .bold)).foregroundStyle(.white).lineLimit(2)
                Text([meta.releaseInfo.map { String($0.prefix(4)) }, String(format: "S%02dE%02d", ep.season, ep.episode),
                      ep.released.map { String($0.prefix(10)) }, ep.name].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: TV.sp(13.5))).foregroundStyle(.white)
                if let d = ep.overview, !d.isEmpty {
                    Text(d).font(.system(size: TV.sp(13))).foregroundStyle(TV.detailDesc).lineLimit(8)
                        .frame(width: TV.dp(480), alignment: .leading)
                }
                if let pct = resumePct {
                    Text("Resume from \(pct)%").font(.system(size: TV.sp(12.5))).foregroundStyle(TV.accent)
                }
                if session.canStream {
                    StreamList(meta: meta, season: ep.season, episode: ep.episode, episodes: episodes)
                        .padding(.top, TV.dp(16))
                }
            }
            .padding(.leading, TV.dp(30)).padding(.top, TV.dp(32)).padding(.trailing, TV.dp(16))
        }
        .ignoresSafeArea()
    }
    private var resumePct: Int? {
        guard let s = (session.pstate()["positions"] as? [String: Any])?[ep.id] as? String else { return nil }
        let p = s.split(separator: "|")
        guard p.count >= 2, let pos = Double(p[0]), let dur = Double(p[1]), dur > 0, pos > 60_000 else { return nil }
        return Int(pos / dur * 100)
    }
}
#endif
