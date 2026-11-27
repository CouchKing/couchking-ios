import SwiftUI

#if os(iOS)

// The Downloads TAB (Android buildTab parity, iPhone only): auto-delete toggle, Movies section,
// Shows section with show → episodes drill-in, each item shows title + size (GB, 1 decimal), a
// live bar while downloading, ▶ Play and 🗑 Delete. Tap a finished row to play it LOCALLY —
// the file URL goes straight into the normal PlayerView with offline=true.
@MainActor
struct DownloadsView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var dl = Downloads.shared
    @State private var play: PlayRequest?
    @State private var pendingDelete: Downloads.Item?
    @State private var note = ""
    // consumed by Downloads.watchedOffline() on the player's exit path (Android autoDelete pref)
    @AppStorage("dlAutoDeleteWatched") private var autoDelete = false

    private var mine: [Downloads.Item] { dl.items(for: session) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow
                    if mine.isEmpty { empty } else { content }
                }
                .padding(.horizontal, Platform.gutter).padding(.bottom, 20)
                .frame(width: geo.size.width, alignment: .leading)
            }
            }
            .background(Theme.bg)
            .navigationTitle("Downloads")
            .ckInlineTitle()
        }
        .ckFullScreenCover(item: $play) { req in PlayerView(request: req) }
        .alert("Delete this download?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { it in
            Button("Delete", role: .destructive) { dl.delete(it) }
            Button("Cancel", role: .cancel) {}
        } message: { it in
            Text(it.state == "downloading" || it.state == "queued"
                 ? "This stops the transfer and removes the partial file."
                 : "It's saved on this device — you can re-download any time.")
        }
        .alert("CouchKing", isPresented: Binding(get: { !note.isEmpty }, set: { if !$0 { note = "" } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(note) }
    }

    // header toggle: auto-delete watched (Android parity) — device-local, like Android's prefs
    private var toggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-delete watched").font(.subheadline.weight(.semibold))
                Text("Finish something and its download cleans itself up")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            Spacer()
            Toggle("", isOn: $autoDelete).labelsHidden().tint(Theme.accent)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
    }

    private var empty: some View {
        Text("Nothing saved yet.\n\nTap Download on a movie page or an episode to keep it on this phone — it plays with no internet at all.")
            .font(.subheadline).foregroundStyle(Theme.dim).lineSpacing(4)
            .padding(.top, 18)
    }

    @ViewBuilder private var content: some View {
        let movies = mine.filter { $0.type != "series" }
        let shows = Dictionary(grouping: mine.filter { $0.type == "series" },
                               by: { $0.showName.isEmpty ? $0.itemId : $0.showName })
        if !movies.isEmpty {
            Text("Movies").font(.headline).padding(.top, 8)
            ForEach(movies) { itemRow($0, thumb: true) }
        }
        if !shows.isEmpty {
            Text("Shows").font(.headline).padding(.top, 8)
            // newest show first (its newest episode's ts — items(for:) is already ts-sorted)
            ForEach(shows.keys.sorted { (shows[$0]?.first?.ts ?? 0) > (shows[$1]?.first?.ts ?? 0) },
                    id: \.self) { show in
                showGroup(show, eps: shows[show] ?? [])
            }
        }
    }

    private func showGroup(_ show: String, eps: [Downloads.Item]) -> some View {
        DisclosureGroup {
            ForEach(eps.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }) {
                itemRow($0, thumb: false)
            }
        } label: {
            HStack(spacing: 10) {
                thumbView(eps.first(where: { !$0.poster.isEmpty })?.poster)
                VStack(alignment: .leading, spacing: 2) {
                    Text(show).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(.primary)
                    let done = eps.filter { $0.state == "done" }
                    Text("\(eps.count) episode\(eps.count == 1 ? "" : "s") · \(Downloads.gb(done.map(\.sizeBytes).reduce(0, +))) GB")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
        }
        .tint(Theme.dim)
    }

    /// One item line: [poster] title / size-or-bar-or-state, then ▶ · ↻ · 🗑 (Android itemRow).
    private func itemRow(_ it: Downloads.Item, thumb: Bool) -> some View {
        HStack(spacing: 10) {
            if thumb { thumbView(it.poster.isEmpty ? nil : it.poster) }
            VStack(alignment: .leading, spacing: 3) {
                Text(thumb ? it.showName
                           : "S\(it.season) E\(it.episode) · \(it.epName.isEmpty ? "Episode \(it.episode)" : it.epName)")
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                stateLine(it)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if it.state == "done" {
                glyphButton("play.fill", bg: Theme.accent, fg: .white) { startPlay(it) }
            }
            if it.state == "failed" {
                glyphButton("arrow.clockwise", bg: Theme.card, fg: .primary) { dl.retry(it) }
            }
            glyphButton("trash", bg: Theme.card, fg: .primary) { pendingDelete = it }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { if it.state == "done" { startPlay(it) } }
        .contextMenu {
            if it.state == "done" {
                Button { startPlay(it) } label: { Label("Play", systemImage: "play.fill") }
            }
            if it.state == "failed" {
                Button { dl.retry(it) } label: { Label("Try again", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive) { pendingDelete = it } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private func stateLine(_ it: Downloads.Item) -> some View {
        switch it.state {
        case "done":
            // MKV warning: AVFoundation can't open Matroska locally (online it rides the
            // server remux — offline there is no server). Gold so it's visible, not scary.
            Text("\(Downloads.gb(it.sizeBytes)) GB" + (it.isMKV ? " · MKV — may not play on iPhone" : ""))
                .font(.caption).foregroundStyle(it.isMKV ? Theme.gold : Theme.dim)
        case "queued":
            Text("Waiting…").font(.caption).foregroundStyle(Theme.dim)
        case "downloading":
            VStack(alignment: .leading, spacing: 3) {
                if let p = dl.progress[it.key], p.total > 0 {
                    ProgressView(value: min(Double(p.got), Double(p.total)), total: Double(p.total))
                        .tint(Theme.accent)
                    Text("\(Downloads.gb(p.got)) / \(Downloads.gb(p.total)) GB")
                        .font(.caption).foregroundStyle(Theme.dim)
                } else {
                    ProgressView().tint(Theme.accent)
                    Text(dl.progress[it.key].map { "\(Downloads.gb($0.got)) GB…" } ?? "Starting…")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
        default:
            Text("Failed — " + (it.note ?? "try again or delete"))
                .font(.caption).foregroundStyle(Theme.gold)
        }
    }

    private func startPlay(_ it: Downloads.Item) {
        if let req = dl.playRequest(it) { play = req }
        else { note = "That download isn't ready." }
    }

    private func thumbView(_ poster: String?) -> some View {
        AsyncImage(url: URL(string: poster ?? "")) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Theme.card }
        .frame(width: 44, height: 66).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func glyphButton(_ icon: String, bg: Color, fg: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15))
                .frame(width: 38, height: 38)
                .background(bg, in: Circle())
                .foregroundStyle(fg)
        }
        .buttonStyle(.plain)
    }
}

/// The whole download control in one view (Android Downloads.button), so call sites stay one
/// guarded line. `circle` = the Details-page ActionCircle look; default = the episode-page
/// capsule (matches "Mark watched"). Tap: not saved → resolve + size-confirm + enqueue;
/// in flight → points at the tab; saved → delete confirm.
@MainActor
struct DownloadButton: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var dl = Downloads.shared
    let meta: Meta
    var season: Int? = nil
    var episode: Int? = nil
    var epName: String? = nil
    var circle = false

    @State private var busy = false
    @State private var offer: Downloads.Offer?
    @State private var confirm = false
    @State private var note = ""
    @State private var confirmDelete = false

    private var itemId: String {
        if let s = season, let e = episode { return "\(meta.id):\(s):\(e)" }
        return meta.id
    }
    private var st: String { dl.state(itemId, session: session) }
    private var icon: String {
        switch st {
        case "done": return "checkmark.circle"
        case "queued", "downloading": return "ellipsis.circle"
        default: return "arrow.down.circle"
        }
    }
    private var label: String {
        if busy { return "Finding…" }
        switch st {
        case "done": return "Saved"
        case "queued", "downloading": return "Downloading"
        default: return "Download"
        }
    }

    var body: some View {
        Group {
            if circle {
                ActionCircle(icon: icon, active: st == "done", label: label) { tap() }
            } else {
                Button { tap() } label: {
                    Label(label, systemImage: icon)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.card, in: Capsule())
                        .foregroundStyle(st == "done" ? Theme.accent : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(busy)
        .alert(Text("Download \(meta.name)?"), isPresented: $confirm, presenting: offer) { o in
            Button("Download") {
                dl.enqueue(o, session: session)
                // let the confirm dismiss settle before the follow-up presents
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    note = "Downloading — see the Downloads tab."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { o in Text(o.line) }
        .alert("CouchKing", isPresented: Binding(get: { !note.isEmpty }, set: { if !$0 { note = "" } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(note) }
        .alert("Delete this download?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let it = dl.items(for: session).first(where: { $0.itemId == itemId }) { dl.delete(it) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It's saved on this device — you can re-download any time.") }
    }

    private func tap() {
        switch st {
        case "done": confirmDelete = true
        case "queued", "downloading": note = "Already downloading — see the Downloads tab."
        default:
            guard !busy else { return }
            busy = true
            Task {
                let o = await dl.resolveOffer(session: session, meta: meta,
                                              season: season, episode: episode, epName: epName)
                busy = false
                if let o { offer = o; confirm = true }
                else { note = "No stream to download yet — try again shortly." }
            }
        }
    }
}

#endif
