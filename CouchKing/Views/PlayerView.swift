import SwiftUI
import AVKit

// Player — AVPlayer over the /webplay fMP4 remux (H.264 + AAC) so every stream the
// resolver serves plays natively, same pipeline the web app uses. Skip-intro/recap and
// resume positions ride the same addon /player endpoints as Android (wired in phase 2).
struct PlayerView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let meta: Meta
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear { start() }
            .onDisappear { stop() }
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .padding()
            }
    }

    private func start() {
        // Direct URL first; if the container/codec isn't AVPlayer-friendly the item fails
        // and we fall back to the server-side /webplay remux (video copy + AAC stereo).
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        Task {
            try? await Task.sleep(for: .seconds(4))
            if item.status == .failed { playRemux(from: 0) }
        }
    }

    private func playRemux(from seconds: Int) {
        let b64 = url.absoluteString.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let remux = URL(string: API.serviceBase + "/webplay?u=\(b64)&t=\(seconds)") else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: remux))
        player.play()
    }

    private func stop() {
        // save resume position into the profile state (same positions map as Android)
        let pos = Int(player.currentTime().seconds * 1000)
        let dur = Int((player.currentItem?.duration.seconds ?? 0).isFinite
                      ? (player.currentItem?.duration.seconds ?? 0) * 1000 : 0)
        if pos > 5000 {
            var ps = session.pstate()
            var positions = ps["positions"] as? [String: Any] ?? [:]
            positions[meta.id] = "\(pos)|\(dur)|\(Int(Date().timeIntervalSince1970 * 1000))"
            ps["positions"] = positions
            session.setPstate(ps)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
