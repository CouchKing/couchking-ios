#if os(tvOS) || os(macOS)
import SwiftUI

// Settings on Apple TV + Mac — the hub BOTH reference apps draw (Firestick MainActivity
// showSettings / showPlayerSettings / showAddons / showAbout / showShelfPicker /
// showShelfReorder + settingRow2; desktop app.js renderSettings / settingsSub + style.css
// .user-card / .ssection / .srow): title, user card (avatar letter · email · access line),
// account rows, a SETTINGS section of value rows, and category sub-pages — not one long form.
// Apple TV: 1dp = 2pt, rows fill #2C2649 on focus (no ring). Mac: rows max 560px, hover #241F3D.
// Sub-pages are value routes so the Apple TV shell's Menu button pops them one at a time.

enum HubRoute: Hashable { case signIn, forgot, player, addons, about, terms, privacy, shelves, reorder }

struct SettingsHub: View {
    @EnvironmentObject var session: Session
    @Environment(\.ckClose) private var ckClose
    @State private var syncMsg = ""
    @State private var err = ""
    @State private var confirmDelete = false

    var body: some View {
        HubPage(title: "Settings", root: true, onBack: ckClose) {
            HubUserCard(accessLine: accessLine)
            if session.signedIn {
                HubRow(label: "Sync library now", value: syncMsg) {
                    syncMsg = "Syncing…"
                    Task {
                        await session.pull(); await session.checkAccess()
                        syncMsg = "Library synced"
                        try? await Task.sleep(for: .seconds(2))
                        syncMsg = ""
                    }
                }
                HubRow(label: "Sign out") { session.signOut() }
                HubRow(label: "Delete account") { confirmDelete = true }
                if !err.isEmpty { HubDim(text: err) }
            }
            HubSection(text: "SETTINGS")
            HubLink(label: "Shelves", value: "\(session.enabledShelves().count) shelves", route: .shelves)
            HubLink(label: "Reorder shelves", value: "Set the order they show on Home", route: .reorder)
            HubRow(label: "Blur unwatched episode images", value: session.pref("blurUnwatched", false) ? "On" : "Off") {
                session.setPref("blurUnwatched", !session.pref("blurUnwatched", false))
            }
            HubRow(label: "Show titles under posters", value: session.pref("showTitles", true) ? "On" : "Off") {
                session.setPref("showTitles", !session.pref("showTitles", true))
            }
            // Player settings only exist when there's something to play
            if session.hasAddon { HubLink(label: "Player", route: .player) }
            HubLink(label: "Addons", value: session.signedIn ? "\(session.addons.count) added" : "sign in to add", route: .addons)
            HubLink(label: "Legal & About", route: .about)
        }
        .navigationDestination(for: HubRoute.self) { r in
            switch r {
            case .signIn: HubSignIn()
            case .forgot: HubForgot()
            case .player: HubPlayer()
            case .addons: HubAddons()
            case .about: HubAbout()
            case .terms: HubText(title: "Terms & Conditions", text: Legal.terms)
            case .privacy: HubText(title: "Privacy Policy", text: Legal.privacy)
            case .shelves: HubShelves()
            case .reorder: HubReorder()
            }
        }
        // silent service-assignment refresh on open (showSettings)
        .task { await session.checkAccess() }
        .overlay {
            if confirmDelete {
                ConfirmCard(title: "Delete account?",
                            text: "This permanently deletes your account and synced library on the server.",
                            confirm: "Delete") {
                    confirmDelete = false
                    Task { if !(await session.deleteAccount()) { err = "Couldn't delete — check your connection" } }
                } cancel: { confirmDelete = false }
            }
        }
    }

    private var accessLine: String {
        if !session.signedIn { return "Tap to sign in" }
        if session.accessDaysLeft > 3650 { return "Lifetime access" }
        if !session.accessExpiry.isEmpty && session.accessDaysLeft <= 0 { return "⛔ Subscription expired — renew to keep watching" }
        if !session.accessExpiry.isEmpty { return "Access through \(session.accessExpiry) · \(session.accessDaysLeft) days left" }
        return "Signed in"
    }
}

// MARK: - building blocks

enum HubRowGap {
    #if os(tvOS)
    static let v = TV.dp(4)
    #else
    static let v: CGFloat = 7.2
    #endif
}

enum Hub {
    #if os(tvOS)
    static let bg = TV.bg, card = TV.card, dim = TV.dim, accent = TV.accent
    #else
    static let bg = Desk.bg, card = Desk.card, dim = Desk.muted, accent = Desk.accent
    #endif
}

/// Page shell: Apple TV = "‹" icon button (44dp #2C2649 circle) + 24sp bold title, 16dp padding;
/// Mac = "‹ Back" ghost (sub-pages) + h2, `.page` padding.
struct HubPage<Content: View>: View {
    let title: String
    var root = false
    var onBack: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                if root {
                    HStack(spacing: 0) {
                        backButton
                        Text("  " + title).font(.system(size: TV.sp(24), weight: .bold)).foregroundStyle(.white)
                    }
                } else {
                    backButton
                    Text(title).font(.system(size: TV.sp(24), weight: .bold)).foregroundStyle(.white)
                        .padding(.top, TV.dp(8)).padding(.bottom, TV.dp(6))
                }
                content
                #else
                if !root { DeskBack() }
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.fg)
                    .padding(.top, 6.4).padding(.bottom, 9.6)
                content
                #endif
            }
            #if os(tvOS)
            .padding(TV.dp(16))
            #else
            .padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide).padding(.bottom, Desk.pageBottom)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Hub.bg.ignoresSafeArea())
        #if os(macOS)
        .navigationBarBackButtonHidden(true)
        #endif
    }

    #if os(tvOS)
    private var backButton: some View {
        Button { if let onBack { onBack() } else { dismiss() } } label: {
            Text("‹").font(.system(size: TV.sp(18))).foregroundStyle(.white)
                .frame(width: TV.dp(44), height: TV.dp(44))
                .background(TV.chip, in: RoundedRectangle(cornerRadius: TV.dp(20)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(20)))
    }
    #endif
}

/// settingRow2 / `.srow`: label · value · ›. Apple TV: card r10, 14/13dp padding, 16sp / 14sp,
/// focused fill #2C2649. Mac: card r12, .85rem 1rem padding, bold label, muted bold value,
/// hover #241F3D; a static row hides its chevron and never highlights.
struct HubRowLabel: View {
    let label: String
    var value = ""
    var isStatic = false
    var body: some View {
        #if os(tvOS)
        HStack(spacing: 0) {
            Text(label).font(.system(size: TV.sp(16))).foregroundStyle(.white)
            Spacer(minLength: TV.dp(8))
            if !value.isEmpty {
                Text(value).font(.system(size: TV.sp(14))).foregroundStyle(TV.dim).padding(.trailing, TV.dp(8))
            }
            Text("›").font(.system(size: TV.sp(18))).foregroundStyle(TV.dim)
        }
        .padding(.horizontal, TV.dp(14)).padding(.vertical, TV.dp(13))
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        HStack(spacing: 12.8) {
            Text(label).font(.system(size: 16, weight: .bold)).foregroundStyle(Desk.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !value.isEmpty {
                Text(value).font(.system(size: 14.4, weight: .bold)).foregroundStyle(Desk.muted)
            }
            Text("›").font(.system(size: 16, weight: .black)).foregroundStyle(Desk.muted).opacity(isStatic ? 0 : 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 13.6)
        .frame(maxWidth: 560, alignment: .leading)
        .contentShape(Rectangle())
        #endif
    }
}

struct HubRowStyle: ButtonStyle {
    var isStatic = false
    func makeBody(configuration: Configuration) -> some View {
        Filled(label: configuration.label, pressed: configuration.isPressed, isStatic: isStatic)
    }
    private struct Filled<L: View>: View {
        let label: L
        let pressed: Bool
        let isStatic: Bool
        #if os(tvOS)
        @Environment(\.isFocused) private var focused
        var body: some View {
            label.background(pressed ? TV.pressFill : (focused ? TV.chip : TV.card),
                             in: RoundedRectangle(cornerRadius: TV.dp(10)))
        }
        #else
        @State private var hover = false
        var body: some View {
            label.background(hover && !isStatic ? Desk.card2 : Desk.card, in: RoundedRectangle(cornerRadius: 12))
                .onHover { hover = $0 }
        }
        #endif
    }
}

struct HubRow: View {
    let label: String
    var value = ""
    var isStatic = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { HubRowLabel(label: label, value: value, isStatic: isStatic) }
            .buttonStyle(HubRowStyle(isStatic: isStatic))
            .padding(.vertical, HubRowGap.v)
    }
}

struct HubLink: View {
    let label: String
    var value = ""
    let route: HubRoute
    var body: some View {
        NavigationLink(value: route) { HubRowLabel(label: label, value: value) }
            .buttonStyle(HubRowStyle())
            .padding(.vertical, HubRowGap.v)
    }
}

/// Firestick sectionText (16sp bold white) / desktop `.ssection` (muted .78rem 800, tracked).
struct HubSection: View {
    let text: String
    var body: some View {
        #if os(tvOS)
        Text(text).font(.system(size: TV.sp(16), weight: .bold)).foregroundStyle(.white)
            .padding(.top, TV.dp(14)).padding(.bottom, TV.dp(6))
        #else
        Text(text).font(.system(size: 12.5, weight: .heavy)).kerning(1).foregroundStyle(Desk.muted)
            .padding(.top, 17.6).padding(.bottom, 4.8)
        #endif
    }
}

struct HubDim: View {
    let text: String
    var body: some View {
        #if os(tvOS)
        Text(text).font(.system(size: TV.sp(13))).foregroundStyle(TV.dim).padding(.vertical, TV.dp(4))
        #else
        Text(text).font(.system(size: 14)).foregroundStyle(Desk.muted).padding(.vertical, 6).frame(maxWidth: 560, alignment: .leading)
        #endif
    }
}

/// Accent pill (Firestick `pill`, 24dp radius) / desktop primary button.
struct HubPill: View {
    let text: String
    let action: () -> Void
    var body: some View {
        #if os(tvOS)
        Button(action: action) {
            Text(text).font(.system(size: TV.sp(14))).foregroundStyle(.white)
                .padding(.horizontal, TV.dp(20)).padding(.vertical, TV.dp(10))
                .background(TV.accent, in: RoundedRectangle(cornerRadius: TV.dp(24)))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(24)))
        .padding(.vertical, TV.dp(6))
        #else
        Button(text, action: action).buttonStyle(DeskButton(kind: .primary)).padding(.vertical, 6)
        #endif
    }
}

/// Firestick `field` (card r8, accent ring on focus) / desktop input.
struct HubField: View {
    let hint: String
    @Binding var text: String
    var secure = false
    var body: some View {
        #if os(tvOS)
        Group {
            if secure { SecureField(hint, text: $text) } else { TextField(hint, text: $text) }
        }
        .font(.system(size: TV.sp(14)))
        .padding(TV.dp(12))
        .background(TV.card, in: RoundedRectangle(cornerRadius: TV.dp(8)))
        .padding(.vertical, TV.dp(6))
        #else
        Group {
            if secure { SecureField(hint, text: $text) } else { TextField(hint, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 16))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Desk.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Desk.border, lineWidth: 1))
        .frame(maxWidth: 480)
        .padding(.vertical, 6)
        #endif
    }
}

/// User card: 52 avatar circle (accent, first letter) · email (Guest) · access line
/// (red when expired). Guests tap it to sign in.
struct HubUserCard: View {
    @EnvironmentObject var session: Session
    let accessLine: String
    var body: some View {
        let letter = String((session.email.first ?? "G")).uppercased()
        let expired = session.signedIn && !session.accessExpiry.isEmpty && session.accessDaysLeft <= 0
        #if os(tvOS)
        let card = HStack(spacing: TV.dp(14)) {
            Text(letter).font(.system(size: TV.sp(22), weight: .bold)).foregroundStyle(.white)
                .frame(width: TV.dp(52), height: TV.dp(52)).background(TV.accent, in: Circle())
            VStack(alignment: .leading, spacing: TV.dp(2)) {
                Text(session.signedIn ? session.email : "Guest").font(.system(size: TV.sp(17), weight: .bold)).foregroundStyle(.white)
                Text(accessLine).font(.system(size: TV.sp(13))).foregroundStyle(expired ? TV.rgb(0xE2574C) : TV.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(TV.dp(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if session.signedIn {
                Button {} label: { card }.buttonStyle(TVRingButton(radius: TV.dp(14)))
                    .background(TV.card, in: RoundedRectangle(cornerRadius: TV.dp(14)))
            } else {
                NavigationLink(value: HubRoute.signIn) { card }.buttonStyle(TVRingButton(radius: TV.dp(14)))
                    .background(TV.card, in: RoundedRectangle(cornerRadius: TV.dp(14)))
            }
        }
        .padding(.top, TV.dp(10)).padding(.bottom, TV.dp(6))
        #else
        let card = HStack(spacing: 14.4) {
            Text(letter).font(.system(size: 21.6, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 52, height: 52).background(Desk.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.signedIn ? session.email : "Guest").font(.system(size: 16.8, weight: .heavy)).foregroundStyle(Desk.fg)
                Text(accessLine).font(.system(size: 13.6)).foregroundStyle(expired ? Desk.danger : Desk.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14.4)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Desk.card, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        Group {
            if session.signedIn { card }
            else { NavigationLink(value: HubRoute.signIn) { card }.buttonStyle(.plain) }
        }
        .padding(.vertical, 9.6)
        #endif
    }
}

// MARK: - sub-pages

/// Player: SUBTITLES (live sample, size, English/Off) · PLAYBACK (autoplay next, seek step).
struct HubPlayer: View {
    @EnvironmentObject var session: Session
    private let sizes: [(String, Double)] = [("Small", 0.8), ("Normal", 1.0), ("Large", 1.3), ("Huge", 1.6)]
    var body: some View {
        let scale = session.pref("subScale", 1.0)
        let cur = sizes.firstIndex { abs($0.1 - scale) < 0.01 } ?? 1
        HubPage(title: "Player") {
            HubSection(text: "SUBTITLES")
            sample(scale)
            HubRow(label: "Subtitle size", value: sizes[cur].0) {
                session.setPref("subScale", sizes[(cur + 1) % sizes.count].1)
            }
            HubRow(label: "Subtitles", value: session.pref("subLang", "en") == "off" ? "Off" : "English") {
                session.setPref("subLang", session.pref("subLang", "en") == "en" ? "off" : "en")
            }
            HubSection(text: "PLAYBACK")
            HubRow(label: "Autoplay next episode", value: session.pref("autoplayNext", true) ? "On" : "Off") {
                session.setPref("autoplayNext", !session.pref("autoplayNext", true))
            }
            HubRow(label: "Seek step", value: "\(session.pref("seekStep", 10))s") {
                let steps = [5, 10, 15, 30]
                let i = steps.firstIndex(of: session.pref("seekStep", 10)) ?? 1
                session.setPref("seekStep", steps[(i + 1) % steps.count])
            }
        }
    }

    /// The live sample: black r10, 110 tall, "This is what subtitles will look like" at 15 × scale.
    private func sample(_ scale: Double) -> some View {
        let outline = session.pref("subOutline", true)
        let pos = session.pref("subPos", "normal")
        let unit: CGFloat = Platform.isTV ? 2 : 1
        return ZStack(alignment: .bottom) {
            Color.black
            Text("This is what subtitles will look like")
                .font(.system(size: 15 * unit * scale)).foregroundStyle(.white)
                .shadow(color: .black.opacity(outline ? 1 : 0), radius: 2.5)
                .shadow(color: .black.opacity(outline ? 1 : 0), radius: 1, x: 1, y: 1)
                .padding(.horizontal, 8 * unit).padding(.vertical, 2 * unit)
                .background(session.pref("subBg", false) ? Color.black.opacity(0.7) : .clear)
                .padding(.bottom, (pos == "high" ? 46 : pos == "raised" ? 26 : 10) * unit)
        }
        .frame(maxWidth: Platform.isMac ? 560 : .infinity)
        .frame(height: 110 * unit)
        .clipShape(RoundedRectangle(cornerRadius: 10 * unit))
        .padding(.vertical, 6 * unit)
    }
}

/// Addons (showAddons): built-ins, YOUR ADDONS (select = remove), code/URL field + Add, OFFICIAL.
struct HubAddons: View {
    @EnvironmentObject var session: Session
    @State private var code = ""
    @State private var msg = ""
    @State private var probing = false
    var body: some View {
        HubPage(title: "Addons") {
            if !session.signedIn {
                HubDim(text: "Sign in to add addons and start streaming.")
                NavigationLink(value: HubRoute.signIn) { HubPillLabel(text: "Sign in") }
                    .modifier(HubPillStyle())
            } else {
                HubSection(text: "OFFICIAL — BUILT IN")
                HubRow(label: "Cinemeta", value: "Movie & show info · built in", isStatic: true) {}
                HubRow(label: "OpenSubtitles v3", value: "Subtitles · built in", isStatic: true) {}
                HubSection(text: "YOUR ADDONS")
                if session.addons.isEmpty { HubDim(text: "Paste your addon code or URL below to start streaming.") }
                ForEach(session.addons) { a in
                    HubRow(label: a.name, value: "Tap to remove") { session.removeAddon(a.url) }
                }
                HubField(hint: "Addon code or URL", text: $code)
                if !msg.isEmpty { HubDim(text: msg) }
                HubPill(text: probing ? "Adding…" : "Add") { add() }
            }
        }
    }

    /// Probe the manifest and take ITS name — nothing is added until the addon answers.
    private func add() {
        var c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !probing else { if c.isEmpty { msg = "Enter your addon code or URL" }; return }
        if !c.hasPrefix("http") { c = "https://" + c }
        if c.hasSuffix("/manifest.json") { c = String(c.dropLast("/manifest.json".count)) }
        probing = true; msg = ""
        Task {
            guard let m = try? await API.json("/manifest.json", base: c),
                  m["catalogs"] is [[String: Any]] || m["resources"] != nil else {
                msg = "Couldn't add that — check the code or URL"
                probing = false; return
            }
            if let u = URL(string: c), let host = u.host { API.serviceBase = "https://" + host }
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Addon"
            if !session.addons.contains(where: { $0.url == c }) {
                session.addons.append(Addon(url: c, name: name))
                var st = session.state
                st["addons"] = session.addons.map { ["url": $0.url, "name": $0.name] }
                session.state = st
                session.push()
            }
            await session.detectLiveTv(); await session.checkAccess()
            msg = "Added"; code = ""; probing = false
        }
    }
}

struct HubPillLabel: View {
    let text: String
    var body: some View {
        #if os(tvOS)
        Text(text).font(.system(size: TV.sp(14))).foregroundStyle(.white)
            .padding(.horizontal, TV.dp(20)).padding(.vertical, TV.dp(10))
            .background(TV.accent, in: RoundedRectangle(cornerRadius: TV.dp(24)))
        #else
        Text(text)
        #endif
    }
}

struct HubPillStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.buttonStyle(TVRingButton(radius: TV.dp(24))).padding(.vertical, TV.dp(6))
        #else
        content.buttonStyle(DeskButton(kind: .primary)).padding(.vertical, 6)
        #endif
    }
}

/// Legal & About: Terms · Privacy · Version.
struct HubAbout: View {
    var body: some View {
        HubPage(title: "Legal & About") {
            HubLink(label: "Terms & Conditions", route: .terms)
            HubLink(label: "Privacy Policy", route: .privacy)
            HubRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                   isStatic: true) {}
        }
    }
}

struct HubText: View {
    let title: String, text: String
    var body: some View {
        HubPage(title: title) {
            #if os(tvOS)
            // focusable paragraphs so the remote can scroll the long text
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                Button {} label: {
                    Text(para).font(.system(size: TV.sp(13))).foregroundStyle(TV.detailDesc)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(TV.dp(6))
                }
                .buttonStyle(TVRingButton(radius: TV.dp(8), ring: .clear))
            }
            #else
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.text2).textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
            #endif
        }
    }
}

/// Shelves (showShelfPicker): chips numbered in the order you turn them on — accent + bold when
/// on, #241F3D / muted when off. Firestick: two per line; desktop: wrapping chip grid.
struct HubShelves: View {
    @EnvironmentObject var session: Session
    var body: some View {
        let order = session.enabledShelves().map(\.id)
        HubPage(title: "Shelves") {
            HubDim(text: "Turn rows on or off — the number shows where each one lands on Home. For You is always on. Reorder them in Settings → Reorder shelves.")
            ForEach([("movie", "MOVIES"), ("series", "SHOWS")], id: \.0) { t, title in
                let cats = session.allShelves().filter { $0.type == t }
                if !cats.isEmpty {
                    HubSection(text: title)
                    #if os(tvOS)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: TV.dp(6)), GridItem(.flexible(), spacing: TV.dp(6))],
                              spacing: TV.dp(6)) {
                        ForEach(cats) { c in chip(c, order) }
                    }
                    #else
                    FlowRow(spacing: 8) { ForEach(cats) { c in chip(c, order) } }
                    #endif
                }
            }
            HubLink(label: "Reorder shelves", value: "Arrange the order they show on Home", route: .reorder)
        }
    }

    private func chip(_ c: AddonCatalog, _ order: [String]) -> some View {
        let i = order.firstIndex(of: c.id)
        let on = i != nil
        return Button {
            var keys = order
            if on { keys.removeAll { $0 == c.id } } else { keys.append(c.id) }
            session.setShelves(keys)
        } label: {
            #if os(tvOS)
            Text(on ? "\(i! + 1). \(c.name)" : c.name)
                .font(.system(size: TV.sp(14.5), weight: on ? .bold : .regular)).foregroundStyle(on ? .white : TV.dim)
                .lineLimit(1).frame(maxWidth: .infinity)
                .padding(.horizontal, TV.dp(10)).padding(.vertical, TV.dp(12))
                .background(on ? TV.accent : TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(14)))
            #else
            Text(on ? "\(i! + 1). \(c.name)" : c.name)
                .font(.system(size: 14.4, weight: .bold)).foregroundStyle(on ? .white : Desk.muted)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(on ? Desk.accent : Desk.chip, in: RoundedRectangle(cornerRadius: 16))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVRingButton(radius: TV.dp(14)))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Reorder shelves (showShelfReorder): numbered #241F3D rows with ▲ ▼.
struct HubReorder: View {
    @EnvironmentObject var session: Session
    var body: some View {
        let shelves = session.enabledShelves()
        HubPage(title: "Reorder shelves") {
            HubDim(text: Platform.isTV
                   ? "Move a shelf with ▲ ▼ — the whole row highlights so you know which one. This is the order they show on Home."
                   : "Move a shelf with ▲ ▼ to change where it shows on Home. For You always stays on top.")
            if shelves.isEmpty { HubDim(text: "No shelves on yet — add some in Settings → Shelves.") }
            ForEach(Array(shelves.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: 0) {
                    Text("\(i + 1).  \(c.name)").lineLimit(1)
                        #if os(tvOS)
                        .font(.system(size: TV.sp(15))).foregroundStyle(.white)
                        #else
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.fg)
                        #endif
                        .frame(maxWidth: .infinity, alignment: .leading)
                    moveButton("▲", enabled: i > 0) { move(i, by: -1) }
                    moveButton("▼", enabled: i < shelves.count - 1) { move(i, by: 1) }
                }
                #if os(tvOS)
                .padding(.leading, TV.dp(14)).padding(.trailing, TV.dp(8)).padding(.vertical, TV.dp(11))
                .background(TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(12)))
                .focusSection()
                .padding(.vertical, TV.dp(4))
                #else
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: 560)
                .background(Desk.card, in: RoundedRectangle(cornerRadius: 12))
                .padding(.vertical, 4)
                #endif
            }
        }
    }

    @ViewBuilder private func moveButton(_ sym: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(action: act) {
            Text(sym).font(.system(size: TV.sp(20))).foregroundStyle(enabled ? .white : TV.rgb(0x443E66))
                .padding(.horizontal, TV.dp(16)).padding(.vertical, TV.dp(6))
        }
        .buttonStyle(TVRingButton(radius: TV.dp(10)))
        .disabled(!enabled)
        #else
        Button(sym, action: act).buttonStyle(DeskButton(kind: .ghost, small: true)).disabled(!enabled)
            .opacity(enabled ? 1 : 0.35).padding(.leading, 6)
        #endif
    }

    private func move(_ i: Int, by d: Int) {
        var keys = session.enabledShelves().map(\.id)
        let j = i + d
        guard keys.indices.contains(i), keys.indices.contains(j) else { return }
        keys.swapAt(i, j)
        session.setShelves(keys)
    }
}

/// Sign in / create account (the guest user card and Addons both land here).
struct HubSignIn: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var creating = false
    @State private var err = ""
    var body: some View {
        HubPage(title: creating ? "Create account" : "Sign in") {
            HubField(hint: "Email", text: $email)
            HubField(hint: "Password", text: $password, secure: true)
            if creating { HubField(hint: "Your name", text: $name) }
            if !err.isEmpty { HubDim(text: err) }
            HubPill(text: creating ? "Create account" : "Sign in") {
                Task {
                    err = await session.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password,
                                               create: creating, name: name) ?? ""
                    if err.isEmpty && session.signedIn { dismiss() }
                }
            }
            HubRow(label: creating ? "Have an account? Sign in" : "New here? Create one") { creating.toggle(); err = "" }
            HubLink(label: "Forgot password?", route: .forgot)
        }
    }
}

struct HubForgot: View {
    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            DeskBack().padding(.top, Desk.pageTop).padding(.horizontal, Desk.pageSide)
            ForgotPasswordView()
        }
        .background(Desk.bg)
        .navigationBarBackButtonHidden(true)
        #else
        ForgotPasswordView()
        #endif
    }
}
#endif
