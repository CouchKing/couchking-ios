import SwiftUI
import AVKit

#if os(iOS)

// ⊞ MULTIVIEW (Nov 28 — Android MultiviewActivity parity): up to FOUR live channels at once,
// the sports-Sunday screen. Each tile is its own AVPlayer tuned through the exact same
// /stream/tv/{id}.json pick the normal tune uses (HLS first, the steady .ts hub only for
// 24/7 loops), so server slot accounting is untouched — the access gate is probed ONCE and
// every tile rides this device's household IP slot.
//
//  - LAYOUT: adaptive, always-centered 16:9 tiles. 1 = full screen, 2 = side-by-side,
//    3 = one big left + two stacked right (the BIG slot follows the AUDIO owner), 4 = 2x2.
//    A ghost "＋ Add channel" tile occupies the next empty slot until the grid is full.
//  - GESTURES (same as Android phones): TAP = give that tile the sound (🔊/🔇 badges),
//    DOUBLE-TAP = watch that channel full screen (the real player), ✕ on the tile or HOLD =
//    close the screen (slot frees, ＋ returns), ＋ tile = channel picker (★ favorites first,
//    guide order). The visible ✕ exists because hold-to-close is undiscoverable (AJ Nov 28).
//  - LAG: muted tiles are decode-capped (preferredMaximumResolution/peak bitrate) — a
//    quarter-screen tile has no business decoding the full 1080p ladder (Android capDecode).
//  - RESILIENCE: a dying stream never takes the grid down — one silent re-resolve+retune
//    (live URLs go stale), then a visible "tap to retry" state.

@MainActor
final class MVTile: ObservableObject, Identifiable {
    let id = UUID()
    @Published var chId = ""          // "cklive:<id>"
    @Published var name = ""
    @Published var logo = ""
    @Published var status: String? = nil   // "Tuning…" / "⚠ …" overlay line
    @Published var errored = false
    var retried = false               // one silent retune per failure before the visible state
    let player = AVPlayer()
    private var statusObs: NSKeyValueObservation?

    func watch(_ item: AVPlayerItem, onFail: @escaping () -> Void) {
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                guard let self else { return }
                if it.status == .failed { onFail() }
                else if it.status == .readyToPlay { self.status = nil; self.errored = false; self.retried = false }
            }
        }
    }
    func stop() {
        statusObs = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct MultiviewView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var tiles: [MVTile] = []
    @State private var audioId: UUID? = nil
    @State private var guide = LiveGuide()
    @State private var gatePassed = false
    @State private var gate = ""                 // non-empty = the access-gate modal
    @State private var full: Meta? = nil         // double-tap → the real player
    @State private var showPicker = false
    @State private var pickQ = ""                // picker search (web Live parity, AJ Nov 28)
    @State private var hint = true
    private let maxTiles = 4
    private let region = UserDefaults.standard.string(forKey: "liveRegion") ?? ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                let rects = slotRects(count: tiles.count + (tiles.count < maxTiles ? 1 : 0),
                                      w: geo.size.width, h: geo.size.height)
                // the 3-slot layout's BIG screen belongs to whoever owns the SOUND, not to
                // whoever was added first (equal-size layouts never shuffle)
                let ordered: [MVTile] = {
                    guard rects.count == 3, let a = tiles.first(where: { $0.id == audioId }) else { return tiles }
                    return [a] + tiles.filter { $0.id != a.id }
                }()
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, tile in
                    if i < rects.count {
                        TileView(tile: tile, hasAudio: tile.id == audioId, showBadge: tiles.count > 1,
                                 close: { closeTile(tile) })
                            .frame(width: rects[i].width, height: rects[i].height)
                            .position(x: rects[i].midX, y: rects[i].midY)
                            // exclusively() so a double-tap never also fires the single-tap
                            .gesture(TapGesture(count: 2).onEnded { openFull(tile) }
                                .exclusively(before: TapGesture().onEnded { tileTap(tile) }))
                            .onLongPressGesture(minimumDuration: 0.5) { closeTile(tile) }
                    }
                }
                if tiles.count < maxTiles, let slot = rects.last {
                    addTile
                        .frame(width: slot.width, height: slot.height)
                        .position(x: slot.midX, y: slot.midY)
                }
                if hint { hintStrip }
                closeButton
                if !gate.isEmpty { GateModal(text: gate) { dismiss() } }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            PlaybackAudio.activate()
            Platform.lockLandscape(true)
            Platform.keepAwake(true)
            Task { _ = await LiveTV.guide(session, region: region) }   // warm the picker lineup
            Task { try? await Task.sleep(for: .seconds(7)); withAnimation { hint = false } }
            if tiles.isEmpty { showPicker = true }
        }
        .onDisappear {
            for t in tiles { t.stop() }
            Platform.lockLandscape(false)
            Platform.keepAwake(false)
        }
        .sheet(isPresented: $showPicker, onDismiss: { pickQ = "" }) { picker }
        .ckFullScreenCover(item: $full, onDismiss: {
            // back from the real player: the grid is still here — resume every tile
            for t in tiles { t.player.play() }
            applyAudio(); applyCaps()
        }) { c in LiveTuneView(channel: c) }
    }

    // MARK: layout — Android slotRects, centered 16:9 inside each slot

    private func slotRects(count: Int, w: CGFloat, h: CGFloat) -> [CGRect] {
        let slots: [CGRect]
        switch count {
        case 0, 1: slots = [CGRect(x: 0, y: 0, width: w, height: h)]
        case 2: slots = [CGRect(x: 0, y: 0, width: w / 2, height: h),
                         CGRect(x: w / 2, y: 0, width: w / 2, height: h)]
        case 3: slots = [CGRect(x: 0, y: 0, width: w * 2 / 3, height: h),
                         CGRect(x: w * 2 / 3, y: 0, width: w / 3, height: h / 2),
                         CGRect(x: w * 2 / 3, y: h / 2, width: w / 3, height: h / 2)]
        default: slots = [CGRect(x: 0, y: 0, width: w / 2, height: h / 2),
                          CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2),
                          CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2),
                          CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)]
        }
        // largest centered 16:9 inside each slot, minus a small gutter
        return slots.map { r in
            let gw = r.width - 8, gh = r.height - 8
            var tw = gw, th = tw * 9 / 16
            if th > gh { th = gh; tw = th * 16 / 9 }
            return CGRect(x: r.midX - tw / 2, y: r.midY - th / 2, width: tw, height: th)
        }
    }

    // MARK: tiles

    private func tileTap(_ t: MVTile) {
        if t.errored { tune(t, chId: t.chId, name: t.name, logo: t.logo); return }
        audioId = t.id
        applyAudio()
    }

    /// HOLD = close this screen: its decoder frees immediately, the grid re-flows, ＋ returns.
    private func closeTile(_ t: MVTile) {
        t.stop()
        tiles.removeAll { $0.id == t.id }
        if audioId == t.id { audioId = tiles.first?.id }
        applyAudio(); applyCaps()
        if tiles.isEmpty { showPicker = true }
    }

    /// DOUBLE-TAP = leave the grid's tile and watch that channel in the real player.
    private func openFull(_ t: MVTile) {
        guard !t.chId.isEmpty else { return }
        for x in tiles { x.player.pause(); x.player.isMuted = true }   // free the pipes first
        full = Meta(id: t.chId, type: "tv", name: t.name, poster: t.logo.isEmpty ? nil : t.logo)
    }

    private func applyAudio() {
        if audioId == nil || !tiles.contains(where: { $0.id == audioId }) { audioId = tiles.first?.id }
        for t in tiles { t.player.isMuted = t.id != audioId }
    }

    /// Brandon's "laggy" fix (Android capDecode): with 2+ tiles each one is a half/quarter of
    /// the screen — cap every tile's decode so ABR serves the small variant; a lone tile is
    /// uncapped. Applied on every add/close.
    private func applyCaps() {
        for t in tiles {
            guard let item = t.player.currentItem else { continue }
            if tiles.count > 1 {
                item.preferredMaximumResolution = CGSize(width: 960, height: 540)
                item.preferredPeakBitRate = 3_000_000
            } else {
                item.preferredMaximumResolution = .zero
                item.preferredPeakBitRate = 0
            }
        }
    }

    private func addChannel(_ c: LiveChannel) {
        guard tiles.count < maxTiles else { return }
        let t = MVTile()
        tiles.append(t)
        tune(t, chId: c.id.hasPrefix("cklive:") ? c.id : "cklive:" + c.id, name: c.name, logo: c.logo)
    }

    private func tune(_ t: MVTile, chId: String, name: String, logo: String) {
        t.chId = chId; t.name = name; t.logo = logo
        t.errored = false
        t.status = "Tuning \(name.isEmpty ? "channel" : name)…"
        Task {
            guard let base = session.addonBase() else { return }
            let u = session.profileSeg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let r = try? await API.json("/stream/tv/\(chId).json?u=\(u)", base: base),
                  let streams = r["streams"] as? [[String: Any]], !streams.isEmpty else {
                tileError(t, "\(name.isEmpty ? "That channel" : name) is down right now"); return
            }
            // same source pick as the normal tune: hub .ts only for 24/7 loops, HLS otherwise
            let loop = chId.contains("24-7")
            let hls = streams.first { !(($0["ckTs"] as? Bool) ?? false) && ($0["url"] as? String)?.isEmpty == false }
            let ts = streams.first { (($0["ckTs"] as? Bool) ?? false) && ($0["url"] as? String)?.isEmpty == false }
            guard let us = ((loop ? (ts ?? hls) : (hls ?? ts))?["url"] as? String), let url = URL(string: us) else {
                tileError(t, "\(name.isEmpty ? "That channel" : name) is down right now"); return
            }
            // ACCESS GATE once per session — the gate is per-KEY+IP and every tile is this
            // one device, so the first probe covers the whole grid.
            if !gatePassed {
                let code = await API.probe(url)
                if let reason = API.gateReason(code) { gate = reason; return }
                gatePassed = true
            }
            guard tiles.contains(where: { $0.id == t.id }) else { return }
            let item = AVPlayerItem(url: url)
            t.watch(item) { tileFailed(t) }
            t.player.replaceCurrentItem(with: item)
            t.player.play()
            applyAudio(); applyCaps()
        }
    }

    /// One tile dying must never take the grid down: one silent re-resolve+retune (live URLs
    /// go stale), then the visible retry state.
    private func tileFailed(_ t: MVTile) {
        t.player.replaceCurrentItem(with: nil)
        if !t.retried {
            t.retried = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if tiles.contains(where: { $0.id == t.id }) { tune(t, chId: t.chId, name: t.name, logo: t.logo) }
            }
        } else {
            tileError(t, "\(t.name.isEmpty ? "Stream" : t.name) hiccuped — tap to retry")
        }
    }

    private func tileError(_ t: MVTile, _ msg: String) {
        t.errored = true
        t.status = "⚠ " + msg
    }

    // MARK: chrome

    private var addTile: some View {
        Button { showPicker = true } label: {
            VStack(spacing: 6) {
                Text("＋").font(.system(size: 30))
                Text("Add channel").font(.system(size: 15))
            }
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.08, green: 0.06, blue: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, dash: [9, 7])))
        }
        .buttonStyle(.plain)
    }

    private var hintStrip: some View {
        Text("Tap = sound  ·  Double-tap = full screen  ·  ✕ = close  ·  ＋ = add a channel")
            .font(.system(size: 12.5)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color(red: 0.08, green: 0.06, blue: 0.16).opacity(0.85), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 10)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    // MARK: channel picker (★ favorites first, then the lineup in guide order)

    /// name OR what's airing on it right now — the same net the web Live search casts
    private func pickMatch(_ c: LiveChannel) -> Bool {
        let q = pickQ.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        if c.name.localizedCaseInsensitiveContains(q) { return true }
        if let p = c.now(LiveTV.nowMs()), p.t.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    private var picker: some View {
        let favRows = guide.favChannels.filter { guide.favs.contains($0.id) && pickMatch($0) }
        let allRows = guide.channels.filter(pickMatch)
        return NavigationStack {
            List {
                if !favRows.isEmpty {
                    Section("★ Favorites") { ForEach(favRows) { pickerRow($0) } }
                }
                Section(favRows.isEmpty ? "Channels" : "All channels") {
                    ForEach(allRows) { pickerRow($0) }
                    if allRows.isEmpty && !guide.channels.isEmpty {
                        Text("Nothing matches “\(pickQ)”").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $pickQ, prompt: "Search channels")
            .navigationTitle("＋ Add a channel")
            .ckInlineTitle()
            .toolbar { ToolbarItem(placement: .ckTrailing) { Button("Done") { showPicker = false } } }
            .task {
                if case .ok(let g) = await LiveTV.guide(session, region: region) { guide = g }
            }
            .overlay {
                if guide.channels.isEmpty { ProgressView() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pickerRow(_ c: LiveChannel) -> some View {
        Button {
            showPicker = false
            addChannel(c)
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: c.logo)) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
                .frame(width: 44, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.subheadline).lineLimit(1)
                    if let nowP = c.now(LiveTV.nowMs()) {
                        Text(nowP.t).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// One screen of the grid: the video surface + "Tuning…/⚠" line + 🔊/🔇 badge + name label.
private struct TileView: View {
    @ObservedObject var tile: MVTile
    let hasAudio: Bool
    let showBadge: Bool
    let close: () -> Void
    var body: some View {
        ZStack {
            MVPlayerSurface(player: tile.player)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if let s = tile.status {
                Text(s)
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .overlay(alignment: .topTrailing) {
            // ✕ always visible — hold-to-close alone was undiscoverable (AJ Nov 28)
            HStack(spacing: 6) {
                if showBadge {
                    Text(hasAudio ? "🔊" : "🔇").font(.system(size: 13))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if !tile.name.isEmpty {
                Text(tile.name).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                    .padding(6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hasAudio && showBadge ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// A bare AVPlayerLayer surface for a grid tile (no PiP, no controls — the grid owns every tap).
private struct MVPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

#endif
