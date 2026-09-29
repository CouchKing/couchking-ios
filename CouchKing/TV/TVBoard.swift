#if os(tvOS)
import SwiftUI

// The Firestick board (MainActivity buildTvBoard ~4245), used by Home / Search / Discover /
// Library: the FOCUSED title's backdrop fills the screen behind a left + bottom scrim, a 470dp
// info column sits top-left (name 30sp, facts, 4-line description, cast), and the rows live only
// below a 232dp line, sliding under a 236dp top scrim. Focusing a tile scrolls its row so the row
// label sits right under that line — one row at a time, the next label peeking.
@MainActor
final class BoardModel: ObservableObject {
    @Published var meta: Meta?
    @Published var full: [String: Any] = [:]
    @Published var backdrop: String?
    @Published var artAlpha: Double = 1
    private var artTask: Task<Void, Never>?
    private var showcaseTask: Task<Void, Never>?
    private var cache: [String: [String: Any]] = [:]
    private var lastNarrate = Date.distantPast
    weak var session: Session?

    /// Browse narration (tvInfoUpdate): text swaps instantly; old art dims to 45% over 120ms;
    /// new art fetched after a 160ms debounce (instant when cached) and fades in over 180ms.
    func narrate(_ m: Meta, user: Bool = true) {
        if user { lastNarrate = Date() }
        guard meta?.id != m.id else { return }
        meta = m
        full = cache[m.id] ?? [:]
        withAnimation(.easeOut(duration: 0.12)) { artAlpha = 0.45 }
        artTask?.cancel()
        artTask = Task { [weak self] in
            guard let self else { return }
            if self.cache[m.id] == nil { try? await Task.sleep(for: .milliseconds(160)) }
            guard !Task.isCancelled, let session = self.session else { return }
            var f: [String: Any]
            if let cached = self.cache[m.id] { f = cached }
            else { f = await Catalog.fullMeta(session: session, type: m.type, id: m.id) }
            guard !Task.isCancelled, self.meta?.id == m.id else { return }
            self.cache[m.id] = f
            self.full = f
            self.backdrop = (f["background"] as? String) ?? m.background
                ?? "https://images.metahub.space/background/medium/\(m.id)/img"
            withAnimation(.easeOut(duration: 0.18)) { self.artAlpha = 1 }
        }
    }

    /// Idle showcase: narrate trending titles, advancing every 9s but only after 15s with no
    /// browse narration.
    func startShowcase(_ pool: [Meta]) {
        showcaseTask?.cancel()
        guard !pool.isEmpty else { return }
        if meta == nil { narrate(pool[0], user: false) }
        showcaseTask = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastNarrate) >= 15 {
                    i = (i + 1) % pool.count
                    self.narrate(pool[i], user: false)
                }
            }
        }
    }
}

/// The board surface + info column; `rows` is the scrolling content below the 232dp line.
struct TVBoard<Rows: View>: View {
    @ObservedObject var model: BoardModel
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        ZStack(alignment: .topLeading) {
            TV.bg
            // 1. backdrop, full screen
            AsyncImage(url: URL(string: model.backdrop ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.clear }
            .frame(width: 1920, height: 1080).clipped()
            .opacity(model.artAlpha)
            // 2. left gradient  #E60C0B14 → #990C0B14 → #330C0B14
            LinearGradient(colors: [TV.argb(0xE60C0B14), TV.argb(0x990C0B14), TV.argb(0x330C0B14)],
                           startPoint: .leading, endPoint: .trailing)
            // 3. bottom gradient  #0C0B14 → #B30C0B14 → transparent → transparent
            LinearGradient(colors: [TV.bg, TV.argb(0xB30C0B14), .clear, .clear],
                           startPoint: .bottom, endPoint: .top)
            // 4. rows, below the 232dp line
            rows()
                .padding(.top, TV.dp(232))
            // 5. top scrim 236dp (rows slide under it)  #D90C0B14 → #8C0C0B14 → transparent
            LinearGradient(colors: [TV.argb(0xD90C0B14), TV.argb(0x8C0C0B14), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: TV.dp(236)).allowsHitTesting(false)
            // 6. info column 470dp, margins left 24dp (+ the 64dp rail), top 20dp
            info
                .frame(width: TV.dp(470), alignment: .leading)
                .padding(.leading, TV.dp(64 + 24)).padding(.top, TV.dp(20))
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var info: some View {
        if let m = model.meta {
            let rich = Meta(model.full, type: m.type) ?? m
            VStack(alignment: .leading, spacing: 0) {
                Text(m.name).font(.system(size: TV.sp(30), weight: .bold)).foregroundStyle(.white)
                    .lineLimit(2)
                Text(facts(rich)).font(.system(size: TV.sp(13))).foregroundStyle(.white)
                    .padding(.top, TV.dp(4))
                if let d = rich.description, !d.isEmpty {
                    Text(d).font(.system(size: TV.sp(13))).foregroundStyle(TV.boardDesc)
                        .lineLimit(4).lineSpacing(TV.sp(13) * 0.2).padding(.top, TV.dp(5))
                }
                let cast = (model.full["cast"] as? [String] ?? []).prefix(4)
                if !cast.isEmpty {
                    Text("Cast: " + cast.joined(separator: ", ")).font(.system(size: TV.sp(12.5)))
                        .foregroundStyle(TV.boardCast).lineLimit(1).padding(.top, TV.dp(4))
                }
            }
        }
    }

    /// `year   runtime   ★ rating   g1 · g2 · g3` (joined by 3 spaces).
    private func facts(_ m: Meta) -> String {
        var p: [String] = []
        if let y = m.releaseInfo { p.append(y) }
        if let r = m.runtime, !r.isEmpty { p.append(r) }
        if let r = m.imdbRating { p.append("★ " + r) }
        if !m.genres.isEmpty { p.append(m.genres.prefix(3).joined(separator: " · ")) }
        return p.joined(separator: "   ")
    }
}

// MARK: rows

/// Row title: 16sp bold white, padding left 8dp, top 14dp, bottom 6dp (Top 10: 17sp).
struct TVRowLabel: View {
    let text: String
    var size: CGFloat = 16
    var body: some View {
        Text(text).font(.system(size: TV.sp(size), weight: .bold)).foregroundStyle(.white)
            .padding(.leading, TV.dp(8)).padding(.top, TV.dp(14)).padding(.bottom, TV.dp(6))
    }
}

/// A leanback row: label + horizontal strip (padding 6/8/6/12dp, 16dp tile gaps). Focusing a
/// tile scrolls the PAGE so this row's label sits under the board line.
struct TVRow<Content: View>: View {
    let id: String
    let label: String?
    var labelSize: CGFloat = 16
    let page: ScrollViewProxy
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label { TVRowLabel(text: label, size: labelSize) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 0) { content() }
                    .padding(.leading, TV.dp(6)).padding(.top, TV.dp(8))
                    .padding(.trailing, TV.dp(6)).padding(.bottom, TV.dp(12))
            }
            .focusSection()
        }
        .id(id)
    }
}

/// Firestick poster tile (poster() ~3433): 112×168dp, r10, #1B1830 bg; focus = scale 1.08 over
/// 120ms + lift, NO ring; 12sp medium white single-line title (poster + 8dp wide); badges:
/// in-library ✓ (accent circle 22dp top-end), watched ✓ (black pill, 1dp gold stroke,
/// top-start), +N (accent pill top-start); white 4dp progress bar inset 9dp (2–97%).
struct TVPoster: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    var progress: Double = 0
    var newEps: Int = 0
    static let w = TV.dp(112), h = TV.dp(168)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { TV.card }
                .frame(width: Self.w, height: Self.h)
                .background(TV.card)
                .clipShape(RoundedRectangle(cornerRadius: TV.dp(10)))
                badges
            }
            .frame(width: Self.w, height: Self.h)
            if session.pref("showTitles", true) {
                Text(meta.name).font(.system(size: TV.sp(12), weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).frame(width: Self.w + TV.dp(8))
                    .padding(.top, TV.dp(2)).padding(.bottom, TV.dp(4))
            }
        }
    }

    @ViewBuilder private var badges: some View {
        let inLib = session.inLibrary(meta.id)
        let done = session.isWatched(meta.id)
        ZStack {
            VStack(alignment: .leading, spacing: TV.dp(4)) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: TV.dp(6)) {
                        if newEps > 0 {
                            Text("+\(newEps)").font(.system(size: TV.sp(12), weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, TV.dp(7)).padding(.vertical, TV.dp(2))
                                .background(TV.accent, in: RoundedRectangle(cornerRadius: TV.dp(10)))
                        }
                        if done {
                            Text("✓").font(.system(size: TV.sp(11), weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, TV.dp(5)).padding(.vertical, TV.dp(2))
                                .background(TV.argb(0xCC000000), in: RoundedRectangle(cornerRadius: TV.dp(11)))
                                .overlay(RoundedRectangle(cornerRadius: TV.dp(11)).stroke(TV.gold, lineWidth: TV.dp(1)))
                        }
                    }
                    Spacer()
                    if inLib {
                        Text("✓").font(.system(size: TV.sp(12), weight: .bold)).foregroundStyle(.white)
                            .frame(width: TV.dp(22), height: TV.dp(22)).background(TV.accent, in: Circle())
                    }
                }
                Spacer()
            }
            .padding(TV.dp(6))
            if progress > 0.02 && progress < 0.97 {
                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: TV.dp(2)).fill(TV.argb(0x59000000))
                        RoundedRectangle(cornerRadius: TV.dp(2)).fill(.white)
                            .frame(width: max(TV.dp(6), (Self.w - TV.dp(18)) * progress))
                    }
                    .frame(width: Self.w - TV.dp(18), height: TV.dp(4))
                    .padding(.bottom, TV.dp(9))
                }
            }
        }
        .frame(width: Self.w, height: Self.h)
    }
}

/// Focusable poster cell: tile + narration on focus + page scroll to its row + long-press menu
/// (Details · Add/Remove Library · Mark Watched/Unwatched · Clear Progress when in CW).
struct TVTile: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    let rowId: String
    let page: ScrollViewProxy
    @ObservedObject var model: BoardModel
    var progress: Double = 0
    var newEps: Int = 0
    var inContinue = false
    var onSelect: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let onSelect {
                Button(action: onSelect) { TVPoster(meta: meta, progress: progress, newEps: newEps) }
            } else {
                NavigationLink(value: meta) { TVPoster(meta: meta, progress: progress, newEps: newEps) }
            }
        }
        .buttonStyle(TVScaleButton(scale: 1.08, duration: 0.12))
        .padding(.horizontal, TV.dp(8)).padding(.vertical, TV.dp(6))
        .focused($focused)
        .onChange(of: focused) { f in
            guard f else { return }
            model.narrate(meta)
            withAnimation(.easeOut(duration: 0.2)) { page.scrollTo(rowId, anchor: .top) }
        }
        .contextMenu { TVTitleMenu(meta: meta, inContinue: inContinue) }
    }
}

/// titleMenu (~3683): Details · Add/Remove Library · Mark as Watched/Unwatched · Clear Progress.
struct TVTitleMenu: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    var inContinue = false
    var body: some View {
        NavigationLink(value: meta) { Label("Details", systemImage: "info.circle") }
        Button(session.inLibrary(meta.id) ? "Remove from Library" : "Add to Library",
               systemImage: session.inLibrary(meta.id) ? "minus.circle" : "plus.circle") { session.toggleLibrary(meta) }
        Button(session.isWatched(meta.id) ? "Mark as Unwatched" : "Mark as Watched",
               systemImage: session.isWatched(meta.id) ? "eye.slash" : "eye") { session.toggleWatched(meta) }
        if inContinue {
            Button("Clear Progress", systemImage: "arrow.uturn.backward") { session.clearProgress(meta) }
        }
    }
}

/// Top 10 cell (addTop10Row ~2839): 168dp wide (232dp for #10), 118sp black numeral
/// #26FFFFFF with a #B3FFFFFF glow bottom-start, the poster bottom-end over it.
struct TVTop10Tile: View {
    @EnvironmentObject var session: Session
    let rank: Int
    let meta: Meta
    let rowId: String
    let page: ScrollViewProxy
    @ObservedObject var model: BoardModel
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Text("\(rank)")
                .font(.system(size: TV.sp(118), weight: .black))
                .tracking(-TV.sp(118) * 0.08)
                .foregroundStyle(TV.argb(0x26FFFFFF))
                .shadow(color: TV.argb(0xB3FFFFFF), radius: TV.dp(2))
                .offset(y: TV.sp(118) * 0.12)
            HStack { Spacer(minLength: 0)
                TVTile(meta: meta, rowId: rowId, page: page, model: model)
            }
        }
        .frame(width: TV.dp(rank >= 10 ? 232 : 168), alignment: .leading)
        .padding(.horizontal, TV.dp(2)).padding(.top, TV.dp(2)).padding(.bottom, TV.dp(4))
    }
}
#endif
