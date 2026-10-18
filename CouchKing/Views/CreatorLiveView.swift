// 🔴 Creator Live (AJ's Twitch) — a banner on Home while he's streaming + a full-screen
// in-app player (WKWebView loading our /live/twitchembed page, parent-authorized). Shows only
// when live; the still frame/title/viewers come from the server's 60s-cached creator.json.
// Parity with the TV/web/desktop clients (AJ Oct 17).
import SwiftUI
#if os(iOS)
import WebKit
#endif

struct CreatorLive: Identifiable {
    var id: String { channel + title }
    let channel: String, name: String, platform: String
    let title: String, game: String
    let viewers: Int
    let thumb: String, embedPath: String
}

/// The Home banner. Tap = open the full-screen player.
struct CreatorBanner: View {
    let info: CreatorLive
    @State private var play = false
    var body: some View {
        Button { play = true } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: info.thumb.isEmpty ? "" :
                    info.thumb + (info.thumb.contains("?") ? "&" : "?") + "cb=\(Int(Date().timeIntervalSince1970) / 30)")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(red: 0.16, green: 0.06, blue: 0.19) }
                .frame(width: 150, height: 86).clipped().cornerRadius(8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("🔴 LIVE").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color(red: 0.9, green: 0.17, blue: 0.22)).cornerRadius(5)
                        Text("\(info.name) · on \(info.platform)").font(.caption.bold())
                            .foregroundStyle(Color(red: 0.79, green: 0.65, blue: 1))
                        if info.viewers > 0 { Text("· \(info.viewers) watching").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(info.title.isEmpty ? "Live now" : info.title).font(.subheadline.bold())
                        .foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                    if !info.game.isEmpty { Text(info.game).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color(red: 0.09, green: 0.07, blue: 0.12))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2).padding(.bottom, 10)
        #if os(iOS)
        .fullScreenCover(isPresented: $play) { CreatorPlayer(info: info) }
        #endif
    }
}

#if os(iOS)

/// Full-screen Twitch player with a chat toggle (phone gets chat; same embed page the other
/// clients use). Close button top-right.
struct CreatorPlayer: View {
    let info: CreatorLive
    @Environment(\.dismiss) private var dismiss
    @State private var chat = false
    private var url: URL? {
        let base = API.serviceBase
        let sep = info.embedPath.contains("?") ? "&" : "?"
        return URL(string: base + info.embedPath + (chat ? "\(sep)chat=1" : ""))
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("🔴 \(info.name)").font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Button { chat.toggle() } label: {
                        Text("💬 Chat").font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(chat ? Theme.accent : Theme.card).foregroundStyle(.white).clipShape(Capsule())
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.bold()).foregroundStyle(.white)
                            .padding(8).background(Theme.card).clipShape(Circle())
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
                if let u = url { TwitchWebView(url: u).id(chat) } else { Spacer() }
            }
        }
    }
}

/// Minimal WKWebView host for the Twitch embed page.
struct TwitchWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.scrollView.isScrollEnabled = true
        w.backgroundColor = .black; w.isOpaque = false
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {
        if w.url != url { w.load(URLRequest(url: url)) }
    }
}
#endif
