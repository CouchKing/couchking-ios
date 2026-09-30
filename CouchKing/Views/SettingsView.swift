import SwiftUI

// Settings — item for item the Android app's settings page (MainActivity showSettings /
// showPlayerSettings / showAddons / showAbout / settingRow2): user card (avatar letter · email or
// Guest · access line) → Sync library now · Sign out · Delete account → SETTINGS: Profile ·
// Shelves · Reorder shelves · Blur unwatched episode images · Show titles under posters ·
// Player · Addons · Legal & About. Apple TV + Mac draw the same hub (SettingsHub.swift).
struct SettingsView: View {
    @EnvironmentObject var session: Session
    @State private var err = ""
    @State private var showLogin = false
    @State private var confirmDelete = false
    @State private var syncMsg = ""

    /// Apple TV hosts Settings in the shell's own navigation stack (so the Menu button knows
    /// when it's at the root); everywhere else it brings its own.
    var embedded = false
    init(embedded: Bool = false) { self.embedded = embedded }

    var body: some View {
        if embedded { page } else { NavigationStack { page } }
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS) || os(macOS)
        SettingsHub()
        #else
        content
        #endif
    }

    #if os(iOS)
    private var content: some View {
        List {
            Section {
                userCard
                if session.signedIn {
                    SettingRow(label: syncMsg.isEmpty ? "Sync library now" : syncMsg) {
                        syncMsg = "Syncing…"
                        Task {
                            await session.pull(); await session.checkAccess(); await session.detectLiveTv()
                            syncMsg = "Library synced"
                            try? await Task.sleep(for: .seconds(2))
                            syncMsg = ""
                        }
                    }
                    SettingRow(label: "Sign out") { session.signOut() }
                    SettingRow(label: "Delete account") { confirmDelete = true }
                    if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            Section("SETTINGS") {
                if session.signedIn, let p = session.profiles.first(where: { $0.id == session.currentProfile }) {
                    SettingRow(label: "Profile", value: p.name) { session.switchProfile("") }   // "Who's watching?" — switch, edit, add
                }
                NavigationLink { ShelfPickerView() } label: {
                    SettingRowLabel(label: "Shelves", value: "\(session.shelfLabels().count) shelves")
                }
                NavigationLink { ShelfReorderView() } label: {
                    SettingRowLabel(label: "Reorder shelves", value: "Set the order they show on Home")
                }
                SettingRow(label: "Blur unwatched episode images", value: session.pref("blurUnwatched", false) ? "On" : "Off") {
                    session.setPref("blurUnwatched", !session.pref("blurUnwatched", false))
                }
                SettingRow(label: "Show titles under posters", value: session.pref("showTitles", true) ? "On" : "Off") {
                    session.setPref("showTitles", !session.pref("showTitles", true))
                }
                // Player settings only exist when there's something to PLAY
                if session.hasAddon {
                    NavigationLink { PlayerSettingsView() } label: { SettingRowLabel(label: "Player", value: "") }
                }
                // guests never see the addon system at all (store-shell rule) — the row
                // exists only for signed-in accounts
                if session.signedIn {
                    NavigationLink { AddonsView() } label: {
                        SettingRowLabel(label: "Addons", value: "\(session.addons.count) added")
                    }
                }
                NavigationLink { LegalView() } label: { SettingRowLabel(label: "Legal & About", value: "") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        // silent service-assignment refresh on open (Android showSettings)
        .task { await session.checkAccess() }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView { showLogin = false }.environmentObject(session)
        }
        // CouchKing-styled centered confirm card instead of the system alert (Sheets.kt)
        .overlay {
            if confirmDelete {
                ConfirmCard(title: "Delete account?",
                            text: "This permanently deletes your account and synced library on the server.",
                            confirm: "Delete") {
                    confirmDelete = false
                    Task {
                        if !(await session.deleteAccount()) {
                            err = "Couldn't delete — check your connection"
                        }
                    }
                } cancel: { confirmDelete = false }
            }
        }
    }

    /// Android user card: 52dp avatar circle with the first letter, email (or Guest), the
    /// access line; a guest taps it to sign in.
    private var userCard: some View {
        let letter = String((session.email.first ?? "G")).uppercased()
        let expired = session.signedIn && !session.accessExpiry.isEmpty && session.accessDaysLeft <= 0
        return Button { if !session.signedIn { showLogin = true } } label: {
            HStack(spacing: 14) {
                Text(letter).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.signedIn ? session.email : "Guest").font(.system(size: 17, weight: .bold)).foregroundStyle(.primary)
                    Text(accessLine).font(.system(size: 13))
                        .foregroundStyle(expired ? Color(red: 0xE2 / 255.0, green: 0x57 / 255.0, blue: 0x4C / 255.0) : Theme.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
    #endif

    /// Account card status line — Android Settings card parity: lifetime / expired /
    /// "Access through … · N days left" / plain signed-in.
    private var accessLine: String {
        if !session.signedIn { return "Tap to sign in" }
        if session.accessDaysLeft > 3650 { return "Lifetime access" }
        // ≤ 0 days = EXPIRED/REVOKED — no ambiguous "expires today" (revoked should read
        // as gone, not like they still have access today)
        if !session.accessExpiry.isEmpty && session.accessDaysLeft <= 0 {
            return "⛔ Subscription expired — renew to keep watching"
        }
        if !session.accessExpiry.isEmpty {
            return "Access through \(session.accessExpiry) · \(session.accessDaysLeft) days left"
        }
        return "Signed in"
    }
}

/// Android settingRow2: label 16sp · value 14sp dim · ›.
struct SettingRowLabel: View {
    let label: String
    var value = ""
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 16)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value).font(.system(size: 14)).foregroundStyle(Theme.dim).lineLimit(1).multilineTextAlignment(.trailing)
            }
        }
    }
}

struct SettingRow: View {
    let label: String
    var value = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingRowLabel(label: label, value: value)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Player page (Android showPlayerSettings): SUBTITLES — live sample, Subtitle size, Subtitles
/// (English / Off); PLAYBACK — Autoplay next episode, Seek step. Keys/values/defaults match
/// Store.kt so cross-device prefs agree.
struct PlayerSettingsView: View {
    @EnvironmentObject var session: Session
    private let sizes: [(String, Double)] = [("Small", 0.8), ("Normal", 1.0), ("Large", 1.3), ("Huge", 1.6)]
    var body: some View {
        let scale: Double = session.pref("subScale", 1.0)
        let cur: Int = sizes.firstIndex { abs($0.1 - scale) < 0.01 } ?? 1
        let subLang: String = session.pref("subLang", "off")
        let autoNext: Bool = session.pref("autoplayNext", true)
        let seek: Int = session.pref("seekStep", 10)
        List {
            Section("SUBTITLES") {
                SubtitlePreview().listRowInsets(EdgeInsets())
                SettingRow(label: "Subtitle size", value: sizes[cur].0) {
                    session.setPref("subScale", sizes[(cur + 1) % sizes.count].1)
                }
                SettingRow(label: "Subtitles", value: subLang == "off" ? "Off" : "English") {
                    session.setPref("subLang", subLang == "off" ? "en" : "off")
                }
            }
            Section("PLAYBACK") {
                SettingRow(label: "Autoplay next episode", value: autoNext ? "On" : "Off") {
                    session.setPref("autoplayNext", !autoNext)
                }
                SettingRow(label: "Seek step", value: "\(seek)s") {
                    let steps = [5, 10, 15, 30]
                    let i = steps.firstIndex(of: seek) ?? 1
                    session.setPref("seekStep", steps[(i + 1) % steps.count])
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #endif
        .background(Theme.bg)
        .navigationTitle("Player")
    }
}

/// Addons page (Android showAddons): OFFICIAL — BUILT IN · YOUR ADDONS (tap to remove) · the
/// code/URL field + Add. Guests get the sign-in pill. Addons are account data: what's added
/// here syncs to every device, and what any device added shows up here.
struct AddonsView: View {
    @EnvironmentObject var session: Session
    @State private var code = ""
    @State private var msg = ""
    @State private var busy = false
    @State private var showLogin = false
    @State private var confirmRemove: Addon?
    var body: some View {
        List {
            if !session.signedIn {
                Section {
                    Text("Sign in to add addons to your account.").foregroundStyle(.secondary)
                    Button("Sign in") { showLogin = true }
                }
            } else {
                Section("OFFICIAL — BUILT IN") {
                    SettingRowLabel(label: "Cinemeta", value: "Movie & show info · built in")
                    SettingRowLabel(label: "OpenSubtitles v3", value: "Subtitles · built in")
                }
                Section("YOUR ADDONS") {
                    if session.addons.isEmpty {
                        Text("Paste your addon code or URL below.").foregroundStyle(.secondary)
                    }
                    ForEach(session.addons) { a in
                        SettingRow(label: a.name, value: "Tap to remove") { confirmRemove = a }
                    }
                    TextField("Addon code or URL", text: $code).ckCodeField()
                    if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(.secondary) }
                    Button(busy ? "Adding…" : "Add") {
                        busy = true; msg = ""
                        Task {
                            let e = await session.addAddon(code)
                            msg = e ?? "Added"
                            if e == nil { code = "" }
                            busy = false
                        }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #endif
        .background(Theme.bg)
        .navigationTitle("Addons")
        #if os(iOS)
        .fullScreenCover(isPresented: $showLogin) { LoginView { showLogin = false }.environmentObject(session) }
        #endif
        .overlay {
            if let a = confirmRemove {
                ConfirmCard(title: "Remove \(a.name)?", text: "It leaves your account on every device.", confirm: "Remove") {
                    session.removeAddon(a.url); confirmRemove = nil
                } cancel: { confirmRemove = nil }
            }
        }
    }
}

/// Toggle bound to a per-profile synced pref (writes the profile state + pushes).
struct PrefToggle: View {
    @EnvironmentObject var session: Session
    let label: String, key: String, def: Bool
    var body: some View {
        Toggle(label, isOn: Binding(
            get: { session.pref(key, def) },
            set: { session.setPref(key, $0) }
        ))
    }
}

struct PrefPicker<T: Hashable>: View {
    @EnvironmentObject var session: Session
    let label: String, key: String, def: T
    let options: [(T, String)]
    var body: some View {
        Picker(label, selection: Binding(
            get: { session.pref(key, def) },
            set: { session.setPref(key, $0) }
        )) {
            ForEach(options, id: \.0) { v, name in Text(name).tag(v) }
        }
    }
}

/// Forgot password (Android showForgotPassword parity): email → 6-digit code (15 min) →
/// new password. The service resets the account token, so other devices just re-prompt.
struct ForgotPasswordView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var prefill: String = ""
    @State private var email = ""
    @State private var code = ""
    @State private var pass = ""
    @State private var pass2 = ""
    @State private var sent = false
    @State private var msg = ""

    var body: some View {
        Form {
            Section {
                Text("We'll email you a 6-digit code — it expires in 15 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Email", text: $email)
                    .ckEmailField()
                Button("Email me the code") { sendCode() }
                    .disabled(!email.contains("@") || !email.contains("."))
            }
            if sent {
                Section {
                    TextField("6-digit code", text: $code).ckNumberField()
                    SecureField("New password (4+ characters)", text: $pass)
                    SecureField("Confirm new password", text: $pass2)
                    Button("Set new password") { reset() }
                }
            }
            if !msg.isEmpty {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Reset password")
        .onAppear { if email.isEmpty { email = prefill } }
    }

    private func sendCode() {
        msg = "Sending…"
        Task {
            _ = try? await API.postJSON("/tvapp/reset-request", body: ["email": email.trimmingCharacters(in: .whitespaces)])
            msg = "If that email has an account, the code is on its way"
            sent = true
        }
    }

    private func reset() {
        let addr = email.trimmingCharacters(in: .whitespaces)
        if code.trimmingCharacters(in: .whitespaces).count != 6 { msg = "Enter the 6-digit code from the email"; return }
        if pass.count < 4 { msg = "Password needs 4+ characters"; return }
        if pass != pass2 { msg = "Passwords don't match"; return }
        Task {
            let r = try? await API.postJSON("/tvapp/reset", body: [
                "email": addr, "code": code.trimmingCharacters(in: .whitespaces), "password": pass])
            guard r?["ok"] as? Bool == true else {
                msg = (r?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Wrong or expired code"
                return
            }
            msg = "Password updated — signing you in"
            if await session.signIn(email: addr, password: pass, create: false) == nil { dismiss() }
            else { msg = "Password updated — sign in with your new password" }
        }
    }
}

struct ProfileEditView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let profile: Profile?
    /// First run (Android showProfileCreate(first = true)): "Create your profile" → the new
    /// profile becomes active and `onDone` continues to the shelves picker.
    var first = false
    var onDone: (() -> Void)? = nil
    @State private var name = ""
    @State private var avatar = ""
    @State private var color = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    FaceCircle(profile: nil, size: 84, glyph: avatar.isEmpty ? String(name.prefix(1)).uppercased() : avatar,
                               tint: color)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                if first {
                    Text("Your watchlist, progress, and picks stay yours.")
                        .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                TextField("Name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }
            Section("Pick an avatar") {
                // avatar AND color picker (Android addAvatarColorPicker) — the hue drives the tile everywhere
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                    ForEach(ProfileChoices.avatars, id: \.self) { a in
                        Button { avatar = a } label: {
                            Text(a).font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(a == avatar ? Theme.accent.opacity(0.45) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .opacity(avatar.isEmpty || a == avatar ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Pick a color") {
                HStack(spacing: 10) {
                    ForEach(ProfileChoices.colors, id: \.self) { c in
                        Button { color = c } label: {
                            RoundedRectangle(cornerRadius: 10).fill(Profile.tint(c)).frame(width: 34, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: c == color ? 2.5 : 0))
                                .opacity(color.isEmpty || c == color ? 1 : 0.5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Button(first ? "Start watching" : (profile == nil ? "Create" : "Save")) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                if let p = profile, session.profiles.count > 1 {
                    Button("Delete profile", role: .destructive) {
                        session.deleteProfile(p.id); dismiss()
                    }
                }
            }
        }
        .navigationTitle(first ? "Create your profile" : (profile == nil ? "Add a profile" : "Edit profile"))
        .onAppear {
            if let p = profile { name = p.name; avatar = p.avatar; color = p.color }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let p = profile {
            session.renameProfile(p.id, name: n, avatar: avatar, color: color)
        } else {
            let id = session.addProfile(name: n, avatar: avatar, color: color)
            if first, let id { session.switchProfile(id) }
        }
        if first { onDone?() } else { dismiss() }
    }
}

struct SubtitlePreview: View {
    @EnvironmentObject var session: Session
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Theme.panel, .black], startPoint: .top, endPoint: .bottom)
            SubtitleText(text: "This is how your subtitles will look.")
                .padding(.bottom, session.pref("subPos", "normal") == "high" ? 40
                         : session.pref("subPos", "normal") == "raised" ? 22 : 8)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets())
    }
}

/// The subtitle cue as the player renders it: scale, background, outline (shadow ring).
struct SubtitleText: View {
    @EnvironmentObject var session: Session
    let text: String
    var body: some View {
        let outline = session.pref("subOutline", true)
        Text(text)
            .font(.system(size: 17 * session.pref("subScale", 1.0), weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(outline ? 1 : 0), radius: 1, x: 1, y: 1)
            .shadow(color: .black.opacity(outline ? 1 : 0), radius: 1, x: -1, y: -1)
            .shadow(color: .black.opacity(outline ? 0.9 : 0), radius: 2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(session.pref("subBg", false) ? .black.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Shelves picker (Android showShelfPicker): grouped sections of chips that flip IN PLACE and
/// are NUMBERED in the order you turn them on — that number is where the row lands on Home.
/// For You is always on (pinned above), so it isn't listed. `onDone` = first run right after
/// creating a profile ("Start watching").
struct ShelfPickerView: View {
    @EnvironmentObject var session: Session
    var onDone: (() -> Void)? = nil
    private let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
    var body: some View {
        let order = session.shelfLabels()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Turn rows on or off — the number shows where each one lands on Home. For You is always on."
                     + (onDone != nil ? " You can reorder them later in Settings." : " Reorder them in Settings → Reorder shelves."))
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(ShelfCatalog.groups, id: \.0) { title, shelves in
                    Text(title).font(.subheadline.bold())
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(shelves, id: \.label) { sh in
                            let idx = order.firstIndex(of: sh.label)
                            Button {
                                var keys = order
                                if let i = idx { keys.remove(at: i) } else { keys.append(sh.label) }
                                session.setShelves(keys)
                            } label: {
                                Text(idx.map { "\($0 + 1). " + sh.label } ?? sh.label)
                                    .font(.footnote.weight(idx != nil ? .bold : .regular))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10).padding(.vertical, 12)
                                    .background(idx != nil ? Theme.accent : Color(red: 0x24 / 255.0, green: 0x1F / 255.0, blue: 0x3D / 255.0),
                                                in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(idx != nil ? .white : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let onDone {
                    Button("Start watching", action: onDone)
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.accent, in: Capsule())
                        .padding(.top, 8)
                } else {
                    NavigationLink { ShelfReorderView() } label: {
                        HStack { Text("Reorder shelves").bold(); Spacer()
                            Text("Arrange the order they show on Home").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        .padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(onDone != nil ? "Pick your shelves" : "Shelves")
        #if os(iOS)
        .navigationBarBackButtonHidden(onDone != nil)
        #endif
    }
}

/// Reorder screen (Android showShelfReorder, TV + mobile): numbered rows, ▲ ▼ move a shelf,
/// saved with the debounced push so every device gets the order.
struct ShelfReorderView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        let labels = session.shelfLabels()
        List {
            Section {
                Text("Move a shelf with ▲ ▼. This is the order they show on Home.")
                    .font(.footnote).foregroundStyle(.secondary)
                if labels.isEmpty { Text("No shelves on yet — add some in Settings → Shelves.").foregroundStyle(.secondary) }
                ForEach(Array(labels.enumerated()), id: \.element) { i, label in
                    HStack(spacing: 8) {
                        Text("\(i + 1).  \(label)").font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Button { move(i, by: -1) } label: { Text("▲").font(.system(size: 18)).padding(.horizontal, 8) }
                            .buttonStyle(.plain).disabled(i == 0).opacity(i == 0 ? 0.3 : 1)
                        Button { move(i, by: 1) } label: { Text("▼").font(.system(size: 18)).padding(.horizontal, 8) }
                            .buttonStyle(.plain).disabled(i == labels.count - 1).opacity(i == labels.count - 1 ? 0.3 : 1)
                    }
                    .listRowBackground(Theme.card2)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #endif
        .background(Theme.bg)
        .navigationTitle("Reorder shelves")
    }

    private func move(_ i: Int, by d: Int) {
        var keys = session.shelfLabels()
        let j = i + d
        guard keys.indices.contains(i), keys.indices.contains(j) else { return }
        keys.swapAt(i, j)
        session.setShelves(keys)
    }
}

/// Legal & About (Android showAbout): Terms & Conditions · Privacy Policy · Version.
struct LegalView: View {
    var body: some View {
        List {
            NavigationLink { LegalTextView(title: "Terms & Conditions", text: Legal.terms) } label: {
                SettingRowLabel(label: "Terms & Conditions")
            }
            NavigationLink { LegalTextView(title: "Privacy Policy", text: Legal.privacy) } label: {
                SettingRowLabel(label: "Privacy Policy")
            }
            SettingRowLabel(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #endif
        .background(Theme.bg)
        .navigationTitle("Legal & About")
    }
}

struct LegalTextView: View {
    let title: String, text: String
    var body: some View {
        ScrollView { Text(text).font(.callout).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            .background(Theme.bg)
            .navigationTitle(title)
            .ckInlineTitle()
    }
}

/// Mandatory store update gate (Android showStoreMandatoryUpdate): BLOCKING screen, one
/// button deep-linking to the App Store listing the service points at (nothing baked).
struct UpdateGateView: View {
    let info: StoreVersion
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("Logo").resizable().scaledToFit().frame(height: 96)
            Text("Update required").font(.title2.bold())
            Text("This version of CouchKing is no longer supported. Update to \(info.latest) to keep watching.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            if let u = URL(string: info.url.isEmpty ? "itms-apps://apps.apple.com" : info.url) {
                Link(destination: u) {
                    Text("Update on the App Store").font(.headline).frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 28).padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}


/// Centered confirm card with the purple focus ring (Android Sheets.kt confirm card).
struct ConfirmCard: View {
    let title: String, text: String, confirm: String
    let action: () -> Void
    let cancel: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture(perform: cancel)
            VStack(spacing: 14) {
                Image("Logo").resizable().scaledToFit().frame(height: 44)
                Text(title).font(.title3.bold())
                Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(action: cancel) {
                        Text("Cancel").font(.headline).padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Theme.card, in: Capsule())
                    }
                    Button(action: action) {
                        Text(confirm).font(.headline).padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
                    }
                }
            }
            .padding(26)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
            .padding(30)
        }
    }
}
