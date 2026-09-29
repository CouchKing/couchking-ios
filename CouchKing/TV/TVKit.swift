#if os(tvOS)
import SwiftUI

// The Firestick (Android TV) look, ported from reference/android-tv/MainActivity.kt.
// Fire TV lays out on a 960×540 dp canvas; Apple TV on 1920×1080 pt → 1dp = 2pt.
enum TV {
    static func dp(_ v: CGFloat) -> CGFloat { v * 2 }
    static func sp(_ v: CGFloat) -> CGFloat { v * 2 }
    static func argb(_ v: UInt32) -> Color {       // Android #AARRGGBB
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: Double((v >> 24) & 0xFF) / 255)
    }
    static func rgb(_ v: UInt32) -> Color { argb(0xFF00_0000 | v) }

    static let bg = rgb(0x0C0B14)          // brand_bg
    static let card = rgb(0x1B1830)
    static let card2 = rgb(0x241F3D)       // dropdowns, stream cards, programme blocks
    static let chip = rgb(0x2C2649)        // chips, icon buttons, focused settings row
    static let accent = rgb(0x7B5BF5)
    static let dim = rgb(0xA9A5C0)
    static let gold = rgb(0xF5C518)
    static let favGold = rgb(0xF5C542)
    static let railSelected = rgb(0x332D55)
    static let railOpen = argb(0xEE0D0B18)
    static let focusFill = argb(0x33FFFFFF)
    static let pressFill = argb(0x4DFFFFFF)
    static let couch = rgb(0xA855F7), king = rgb(0xF0F0F5)
    static let boardDesc = rgb(0xD8D5E6), boardCast = rgb(0x9A94B8)
    static let detailDesc = rgb(0xDDDAEA), epHoverDesc = rgb(0xCFCBE2)
    static let captionGrey = rgb(0xBBBBCC)
}

/// `selBg(color, r, ring = white)`: the focus look of almost every Firestick control — same
/// fill (or #33FFFFFF when transparent) plus a 2dp white stroke; pressed = #4DFFFFFF.
struct TVRingButton: ButtonStyle {
    var radius: CGFloat = 24
    var ring: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        Ringed(label: configuration.label, pressed: configuration.isPressed, radius: radius, ring: ring)
    }
    private struct Ringed<L: View>: View {
        let label: L
        let pressed: Bool
        let radius: CGFloat
        let ring: Color
        @Environment(\.isFocused) private var focused
        var body: some View {
            label
                .overlay(RoundedRectangle(cornerRadius: radius).fill(pressed ? TV.pressFill : .clear))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(ring, lineWidth: focused ? TV.dp(2) : 0))
                .background(RoundedRectangle(cornerRadius: radius).fill(focused ? TV.focusFill : .clear))
        }
    }
}

/// Poster / card focus: scale only (1.08 over 120ms for posters, 1.06 over 110ms for episode
/// cards) plus a lift — NO ring, no tvOS card shine (Firestick tiles).
struct TVScaleButton: ButtonStyle {
    var scale: CGFloat = 1.08
    var duration: Double = 0.12
    func makeBody(configuration: Configuration) -> some View {
        Scaled(label: configuration.label, scale: scale, duration: duration)
    }
    private struct Scaled<L: View>: View {
        let label: L
        let scale: CGFloat
        let duration: Double
        @Environment(\.isFocused) private var focused
        var body: some View {
            label
                .scaleEffect(focused ? scale : 1)
                .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: focused ? 16 : 0, y: focused ? 8 : 0)
                .zIndex(focused ? 1 : 0)
                .animation(.easeOut(duration: duration), value: focused)
        }
    }
}

/// "Couch" (#A855F7) + "King" (#F0F0F5) wordmark, 17sp bold, letterSpacing .02.
struct TVWordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Couch").foregroundStyle(TV.couch)
            Text("King").foregroundStyle(TV.king)
        }
        .font(.system(size: TV.sp(17), weight: .bold)).tracking(0.7)
    }
}
#endif
