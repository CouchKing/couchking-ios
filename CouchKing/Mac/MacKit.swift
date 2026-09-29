#if os(macOS)
import SwiftUI
import AppKit

// The desktop (Electron) app's look, ported 1:1 from reference/desktop/style.css.
// 1rem = 16px. Every value below cites its CSS source.
enum Desk {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: a)
    }
    // :root
    static let bg = hex(0x0C0B14)          // --bg
    static let card = hex(0x1B1830)        // --card
    static let card2 = hex(0x241F3D)       // --card2
    static let accent = hex(0x7B5BF5)      // --accent
    static let muted = hex(0xA9A5C0)       // --muted
    static let fg = Color.white            // --fg
    // named colors
    static let couch = hex(0xA855F7)       // .c1 wordmark "Couch"
    static let king = hex(0xF0F0F5)        // .c2 wordmark "King"
    static let primaryHover = hex(0x8D70FF)
    static let ghostHover = hex(0x2E2850)
    static let border = hex(0x37315C)      // inputs / panels
    static let menuHover = hex(0x332D55)   // menu hover + selected rail pill
    static let railOpen = hex(0x0D0B18, 0xEE / 255.0)
    static let text2 = hex(0xD8D5EA)       // hero sub, poster title, desc
    static let epDesc = hex(0xB9B4D4)
    static let gold = hex(0xF5C518)        // watched badge
    static let seenGreen = hex(0x7CFC9A)
    static let chip = hex(0x2A2545)
    static let chipHover = hex(0x3A3560)
    static let danger = hex(0xE5484D)

    // metrics
    static let rail: CGFloat = 64, railOpen: CGFloat = 200          // --rail / --rail-open
    static let pageTop: CGFloat = 17.6, pageSide: CGFloat = 30.4, pageBottom: CGFloat = 32   // .page
    static let posterW: CGFloat = 146, posterH: CGFloat = 219       // .poster img
    static let stripGap: CGFloat = 12                               // .strip gap .75rem
}

// MARK: buttons (global `button`, `.primary`, `.ghost`, `.small`)

struct DeskButton: ButtonStyle {
    enum Kind { case primary, ghost, danger }
    var kind: Kind = .ghost
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hover in
            configuration.label
                .font(.system(size: small ? 13.6 : 15.2, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, small ? 14.4 : 22.4).padding(.vertical, small ? 7.2 : 12.8)
                .background(bg(hover), in: RoundedRectangle(cornerRadius: 10))
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
    private func bg(_ hover: Bool) -> Color {
        switch kind {
        case .primary: return hover ? Desk.primaryHover : Desk.accent
        case .ghost: return hover ? Desk.ghostHover : Desk.card2
        case .danger: return Desk.danger
        }
    }
}

/// Tracks pointer hover for a subtree.
struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hover = false
    var body: some View { content(hover).onHover { hover = $0 } }
}

/// `.row-label` — 1.1rem / 800, margin 1.1rem 0 .55rem.
struct DeskRowLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 17.6, weight: .heavy)).foregroundStyle(Desk.fg)
            .padding(.top, 17.6).padding(.bottom, 8.8)
    }
}

/// `.strip` — horizontal row, gap .75rem, padding .7rem .6rem 1rem so a hover-scaled poster
/// (and its outline) is never clipped.
struct DeskStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: Desk.stripGap) { content() }
                .padding(.top, 11.2).padding(.horizontal, 9.6).padding(.bottom, 16)
        }
    }
}

/// `.chip` (library/filters): #2a2545 pill, .78rem/700 muted; `.on` = accent + white.
struct DeskChip: View {
    let text: String
    var on = false
    var white = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(on || white ? Color.white : Desk.muted)
                .padding(.horizontal, 9.6).padding(.vertical, 1.9)
                .background(on ? Desk.accent : Desk.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Global `input` look: card bg, 1px #37315C border (accent on focus), radius 10, max 480.
struct DeskField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Desk.accent : Desk.border, lineWidth: 1))
            .focused($focused)
            .frame(maxWidth: 480)
    }
}

// MARK: poster tile (`.poster`, style.css 69-95)

/// EXACT Firestick tile as the desktop draws it: 146×219 r10, hover scale 1.055 (.16s) with a
/// sharp 2px accent outline + deeper shadow, white 4px progress bar inset 9px, single-line
/// centered ellipsized title, badges (✓ list, yellow ✓ watched, +N, S·E chip, hover ✕ on CW).
struct DeskPoster: View {
    @EnvironmentObject var session: Session
    let meta: Meta
    var progress: Double = 0
    var newEps: Int = 0
    var episodeChip: String? = nil
    var continueTile = false
    var onRemove: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4.8) {
            ZStack {
                AsyncImage(url: URL(string: meta.poster ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Desk.card }
                .frame(width: Desk.posterW, height: Desk.posterH)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Desk.accent, lineWidth: hover ? 2 : 0))
                .shadow(color: .black.opacity(hover ? 0.6 : 0.4), radius: hover ? 11 : 7, y: hover ? 6 : 3)
                badges
            }
            .frame(width: Desk.posterW, height: Desk.posterH)
            if session.pref("showTitles", true) {
                Text(meta.name).font(.system(size: 12.8, weight: .semibold))
                    .foregroundStyle(Desk.text2).lineLimit(1).truncationMode(.tail)
                    .frame(width: Desk.posterW).help(meta.name)
            }
        }
        .scaleEffect(hover ? 1.055 : 1)
        .animation(.easeOut(duration: 0.16), value: hover)
        .zIndex(hover ? 2 : 0)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var badges: some View {
        let inList = session.inLibrary(meta.id)
        let done = session.isWatched(meta.id)
        ZStack {
            // `.bar`: shown only between 2% and 97%
            if progress > 0.02 && progress < 0.97 {
                VStack {
                    Spacer()
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0x59 / 255.0))
                            RoundedRectangle(cornerRadius: 2).fill(.white)
                                .frame(width: max(6, g.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 9).padding(.bottom, 9)
                }
            }
            // `.ep-chip` "S2 · E4" just above the bar
            if let chip = episodeChip {
                VStack { Spacer()
                    HStack {
                        Text(chip).font(.system(size: 11.5, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 2.9)
                            .background(Desk.bg.opacity(0xD9 / 255.0), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0x2A / 255.0), lineWidth: 1))
                        Spacer()
                    }
                    .padding(.leading, 9).padding(.bottom, 18)
                }
            }
            // `.badge-new` +N
            if newEps > 0 {
                VStack { Spacer()
                    HStack {
                        Text("+\(min(newEps, 9))").font(.system(size: 11.5, weight: .black)).foregroundStyle(.white)
                            .padding(.horizontal, 7.2).padding(.vertical, 2.2)
                            .background(Desk.accent, in: Capsule())
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        Spacer()
                    }
                    .padding(.leading, 6.4).padding(.bottom, episodeChip == nil ? 14.4 : 40)
                }
            }
            if continueTile {
                // `.cw-x`: hover-only remove, top-right 26px
                if hover, let onRemove {
                    VStack { HStack { Spacer()
                        RemoveX(action: onRemove)
                    }; Spacer() }.padding(6.4)
                }
            } else {
                VStack {
                    HStack {
                        if done { circleBadge(fill: Desk.gold, check: Desk.bg) }   // `.badge-done` top-left
                        Spacer()
                        if inList { circleBadge(fill: Desk.accent, check: .white) } // `.badge-list` top-right
                    }
                    Spacer()
                }
                .padding(6.4)
            }
        }
        .frame(width: Desk.posterW, height: Desk.posterH)
    }

    private func circleBadge(fill: Color, check: Color) -> some View {
        Text("✓").font(.system(size: 12, weight: .black)).foregroundStyle(check)
            .frame(width: 24, height: 24).background(fill, in: Circle())
            .shadow(color: .black.opacity(0.53), radius: 3, y: 1)
    }
}

private struct RemoveX: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text("✕").font(.system(size: 12.8, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(hover ? Desk.hex(0xC0392B) : Desk.bg.opacity(0xD9 / 255.0), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Remove from Continue Watching")
    }
}

/// `.top10-cell` — huge ghost numeral (118px, 15% white fill with a thin white glow) tucked
/// behind the poster; 52px left padding (88px for #10).
struct DeskTop10Tile: View {
    let rank: Int
    let meta: Meta
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Text("\(rank)")
                .font(.system(size: 118, weight: .black))
                .tracking(-9.4)
                .foregroundStyle(Color.white.opacity(0x26 / 255.0))
                .shadow(color: Color.white.opacity(0xB3 / 255.0), radius: 1)
                .offset(y: 26)            // line-height .78 + bottom:16px
                .padding(.bottom, 16)
            DeskPoster(meta: meta)
                .padding(.leading, rank >= 10 ? 88 : 52)
        }
    }
}

/// Wordmark: 30px crown + "Couch" (#a855f7) "King" (#f0f0f5), 900.
struct DeskWordmark: View {
    var size: CGFloat = 18.4
    var body: some View {
        HStack(spacing: 0) {
            Text("Couch").foregroundStyle(Desk.couch)
            Text("King").foregroundStyle(Desk.king)
        }
        .font(.system(size: size, weight: .black))
    }
}

/// Toast (`#toast`): bottom-centered pill, 2200ms, one at a time.
@MainActor
final class DeskToast: ObservableObject {
    static let shared = DeskToast()
    @Published var text = ""
    private var task: Task<Void, Never>?
    func show(_ t: String) {
        text = t
        task?.cancel()
        task = Task { try? await Task.sleep(for: .milliseconds(2200)); if !Task.isCancelled { text = "" } }
    }
}

struct DeskToastView: View {
    @ObservedObject var toast = DeskToast.shared
    var body: some View {
        VStack {
            Spacer()
            if !toast.text.isEmpty {
                Text(toast.text).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 19.2).padding(.vertical, 9.6)
                    .background(Desk.card2.opacity(0xF2 / 255.0), in: Capsule())
                    .shadow(color: .black.opacity(0.6), radius: 9, y: 4)
                    .padding(.bottom, 26)
            }
        }
        .allowsHitTesting(false)
    }
}
#endif

#if os(macOS)
/// `.stream` row: card bg r10 (hover card2), bold accent source name + a chip per `|` part of
/// the stream name, first description line (#9aa .85rem), second line in accent (note).
struct DeskStreamRow: View {
    let stream: [String: Any]
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let name = stream["name"] as? String ?? "Stream"
        let parts = name.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lines = (stream["title"] as? String ?? stream["description"] as? String ?? "")
            .split(separator: "\n").map(String.init)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3.2) {
                HStack(spacing: 8) {
                    Text(parts.first ?? name).font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accent)
                        .padding(.trailing, 9.6)
                    ForEach(Array(parts.dropFirst().enumerated()), id: \.offset) { _, p in
                        Text(p).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Desk.muted)
                            .padding(.horizontal, 9.6).padding(.vertical, 1.9)
                            .background(Desk.chip, in: Capsule())
                    }
                }
                if let t = lines.first, !t.isEmpty {
                    Text(t).font(.system(size: 13.6)).foregroundStyle(Desk.hex(0x99AAAA)).lineLimit(1)
                }
                if lines.count > 1 {
                    Text(lines[1]).font(.system(size: 13.6)).foregroundStyle(Desk.accent).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 11.2)
            .background(hover ? Desk.card2 : Desk.card, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.bottom, 7.2)
    }
}
#endif
