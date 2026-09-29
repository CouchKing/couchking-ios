import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// One codebase, three platforms. Everything that differs between iPhone, Apple TV (Firestick-
// style leanback, remote/focus driven) and Mac (desktop-app layout, pointer + keyboard) goes
// through here, so the views stay single-source.
enum Platform {
    #if os(tvOS)
    static let isTV = true, isMac = false, isPhone = false
    #elseif os(macOS)
    static let isTV = false, isMac = true, isPhone = false
    #else
    static let isTV = false, isMac = false, isPhone = true
    #endif

    /// Poster tile width: phone rows, 10-foot TV rows, desktop grid.
    static var posterWidth: CGFloat { isTV ? 230 : (isMac ? 150 : 108) }
    /// Row side gutter (TV safe area is wider).
    static var gutter: CGFloat { isTV ? 60 : (isMac ? 24 : 14) }
    /// Hero carousel height.
    static var heroHeight: CGFloat { isTV ? 520 : (isMac ? 360 : 230) }
    /// Details backdrop height.
    static var backdropHeight: CGFloat { isTV ? 560 : (isMac ? 400 : 260) }
    /// Episode thumbnail width (16:9).
    static var episodeThumbWidth: CGFloat { isTV ? 320 : (isMac ? 200 : 128) }
    /// Details action-circle diameter.
    static var actionSize: CGFloat { isTV ? 84 : (isMac ? 52 : 46) }
    /// Tiles per adaptive-grid column minimum.
    static var gridMin: CGFloat { posterWidth }

    #if os(macOS)
    private static var awake: NSObjectProtocol?
    #endif
    /// Keep the display awake while video plays (iOS/tvOS idle timer, Mac display-sleep assertion).
    @MainActor
    static func keepAwake(_ on: Bool) {
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #elseif os(macOS)
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Playing video")
        } else if !on, let a = awake {
            ProcessInfo.processInfo.endActivity(a); awake = nil
        }
        #endif
    }
}

/// Closes the presentation a view lives in when it isn't a system sheet/cover (the Mac's in-window
/// player overlay). Views call `ckClose ?? dismiss`.
private struct CKCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var ckClose: (() -> Void)? {
        get { self[CKCloseKey.self] }
        set { self[CKCloseKey.self] = newValue }
    }
}

#if os(macOS)
/// Window-level overlay host (the desktop's `#web-player { position:fixed; inset:0 }`): shown
/// above the rail + content by MacShell. Presenting while something is up replaces it and chains
/// the close handlers so every presenter's binding resets when the stack finally closes.
@MainActor
final class MacOverlayHost: ObservableObject {
    static let shared = MacOverlayHost()
    @Published var content: AnyView?
    private var onClose: (() -> Void)?
    func present(_ v: AnyView, onClose: @escaping () -> Void) {
        let prev = self.onClose
        self.onClose = { onClose(); prev?() }
        content = v
    }
    func close() {
        let c = onClose
        onClose = nil
        content = nil
        c?()
    }
}

struct MacOverlayPresenter<Item: Identifiable, C: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let content: (Item) -> C
    func body(content view: Content) -> some View {
        view.onChange(of: item?.id) { id in
            guard id != nil, let i = item else { return }
            let host = MacOverlayHost.shared
            host.present(AnyView(content(i).environment(\.ckClose, { host.close() })),
                         onClose: { item = nil; onDismiss?() })
        }
    }
}
#endif

extension ToolbarItemPlacement {
    /// Top-right on iPhone; the platform default elsewhere.
    static var ckTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .automatic
        #endif
    }
    static var ckLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #elseif os(macOS)
        return .navigation
        #else
        return .automatic
        #endif
    }
}

extension View {
    /// Inline navigation title (iPhone only — TV/Mac have no large-title bar).
    @ViewBuilder func ckInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Half/full sheet detents on iPhone; TV/Mac sheets size themselves.
    @ViewBuilder func ckDetents() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
        #elseif os(macOS)
        self.frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
        #else
        self
        #endif
    }

    /// Email field: email keyboard, no auto-capitalisation (phone/TV keyboards only).
    @ViewBuilder func ckEmailField() -> some View {
        #if os(iOS) || os(tvOS)
        self.keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func ckCodeField() -> some View {
        #if os(iOS) || os(tvOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func ckNumberField() -> some View {
        #if os(iOS) || os(tvOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// Full-screen presentation (the player, the Live TV tune screen). The Mac has no
    /// full-screen cover, so it opens as a large sheet over the window.
    func ckFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(macOS)
        // the desktop app plays in-window: a full overlay above the rail + content
        return self.modifier(MacOverlayPresenter(item: item, onDismiss: onDismiss, content: content))
        #else
        return self.fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// Apple TV / Mac: treat a row as one focus section so up/down moves row-to-row and focus
    /// lands on the nearest tile (Firestick leanback rows). No-op on iPhone.
    @ViewBuilder func ckFocusSection() -> some View {
        #if os(tvOS) || os(macOS)
        self.focusSection()
        #else
        self
        #endif
    }

    /// Poster / tile button look: the Apple TV "card" lift-and-shine on focus (Firestick's
    /// focused-poster scale), plain on phone, hover-lift on Mac.
    @ViewBuilder func ckTile() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #elseif os(macOS)
        self.buttonStyle(HoverLiftStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }
}

#if os(macOS)
/// Desktop poster hover: lift + accent ring under the pointer (Electron app hover state).
struct HoverLiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLift(pressed: configuration.isPressed) { configuration.label }
    }
    private struct HoverLift<L: View>: View {
        let pressed: Bool
        @ViewBuilder let label: () -> L
        @State private var hover = false
        var body: some View {
            label()
                .scaleEffect(pressed ? 0.97 : (hover ? 1.05 : 1))
                .shadow(color: .black.opacity(hover ? 0.5 : 0), radius: 10, y: 6)
                .animation(.easeOut(duration: 0.15), value: hover)
                .onHover { hover = $0 }
        }
    }
}
#endif
