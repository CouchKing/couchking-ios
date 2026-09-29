import SwiftUI

// Settings — Android parity: Account / Profiles / Addons / Player settings /
// Look & feel / About. Person-level settings sync per profile (2.0.93 semantics).
struct SettingsView: View {
    @EnvironmentObject var session: Session
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var creating = false
    @State private var err = ""
    @State private var addonCode = ""
    @State private var confirmDelete = false
    @State private var syncMsg = ""
    @State private var addonMsg = ""
    @State private var probing = false

    /// Apple TV hosts Settings in the shell's own navigation stack (so the Menu button knows
    /// when it's at the root); everywhere else it brings its own.
    var embedded = false
    init(embedded: Bool = false) { self.embedded = embedded }

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            Form {
                accountSection
                if session.signedIn { profilesSection }
                addonsSection
                shelvesSection
                playerSection
                lookSection
                aboutSection
            }
            .navigationTitle("Settings")
            // silent service-assignment refresh on open (Android showAddons / onResume)
            .task { await session.checkAccess() }
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

    /// Account card status line — Android Settings card parity: lifetime / expired /
    /// "Access through … · N days left" / plain signed-in.
    private var accessLine: String {
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

    private var accountSection: some View {
        Section("Account") {
            if session.signedIn {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.email).font(.body.bold())
                    Text(accessLine).font(.caption)
                        .foregroundStyle(session.isExpired ? .red : .secondary)
                }
                Button(syncMsg.isEmpty ? "Sync library now" : syncMsg) {
                    syncMsg = "Syncing…"
                    Task {
                        await session.pull(); await session.checkAccess()
                        syncMsg = "Library synced"
                        try? await Task.sleep(for: .seconds(2))
                        syncMsg = ""
                    }
                }
                Button("Sign out", role: .destructive) { session.signOut() }
                Button("Delete account", role: .destructive) { confirmDelete = true }
                if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
            } else {
                TextField("Email", text: $email)
                    .ckEmailField()
                SecureField("Password", text: $password)
                if creating { TextField("Your name", text: $name) }
                if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
                Button(creating ? "Create account" : "Sign in") {
                    Task { err = await session.signIn(email: email, password: password,
                                                     create: creating, name: name) ?? "" }
                }
                Button(creating ? "Have an account? Sign in" : "New here? Create one") {
                    creating.toggle()
                }.font(.footnote)
                NavigationLink("Forgot password?") { ForgotPasswordView(prefill: email) }
                    .font(.footnote)
            }
        }
    }

    private var profilesSection: some View {
        Section("Profiles") {
            ForEach(session.profiles) { p in
                NavigationLink { ProfileEditView(profile: p) } label: {
                    HStack { ProfileAvatar(profile: p, size: 30); Text(p.name)
                        if p.id == session.currentProfile {
                            Spacer(); Text("current").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if session.profiles.count < 5 {
                NavigationLink("Add profile") { ProfileEditView(profile: nil) }
            }
            if session.profiles.count > 1 {
                Button("Switch profile") { session.switchProfile("") }
            }
        }
    }

    /// Addons (Android showAddons): signed-in only — guests get a sign-in prompt; the manifest
    /// is probed + named before anything is added.
    private var addonsSection: some View {
        Section("Addons") {
            if !session.signedIn {
                Text("Sign in to add the addon your account was given.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(session.addons) { a in
                    HStack {
                        Text(a.name)
                        Spacer()
                        Button(role: .destructive) { session.removeAddon(a.url) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                TextField("Access code", text: $addonCode)
                    .ckCodeField()
                if !addonMsg.isEmpty { Text(addonMsg).font(.caption).foregroundStyle(.secondary) }
                Button(probing ? "Checking…" : "Add addon") { addAddon() }
                    .disabled(probing || addonCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Shelves (Android showShelfPicker / showShelfReorder): which catalogs make up Home, in
    /// what order — synced to the profile with a debounced push.
    private var shelvesSection: some View {
        Section("Home shelves") {
            NavigationLink { ShelfPickerView() } label: {
                LabeledContent("Choose shelves", value: "\(session.enabledShelves().count) on")
            }
            NavigationLink("Reorder shelves") { ShelfReorderView() }
        }
    }

    // Keys/values/defaults MATCH Android exactly (Store.kt) so cross-device prefs agree (#148).
    private var playerSection: some View {
        Section("Player") {
            PrefToggle(label: "Autoplay next episode", key: "autoplayNext", def: true)
            PrefPicker(label: "Skip step", key: "seekStep", def: 10,
                       options: [(5, "5s"), (10, "10s"), (15, "15s"), (30, "30s")])
            PrefPicker(label: "Subtitle size", key: "subScale", def: 1.0,
                       options: [(0.8, "Small"), (1.0, "Normal"), (1.3, "Large"), (1.6, "Huge")])
            PrefPicker(label: "Subtitles", key: "subLang", def: "en",
                       options: [("en", "English"), ("off", "Off")])   // Android: English or off only
            PrefToggle(label: "Subtitle background", key: "subBg", def: false)   // Android default: off
            PrefToggle(label: "Subtitle outline", key: "subOutline", def: true)
            PrefPicker(label: "Subtitle position", key: "subPos", def: "normal",
                       options: [("normal", "Normal"), ("raised", "Raised"), ("high", "High")])
            PrefPicker(label: "Aspect", key: "scaleMode", def: "fit",
                       options: [("fit", "Fit"), ("fill", "Fill"), ("zoom", "Zoom")])
            PrefPicker(label: "Audio language", key: "audioLang", def: "en",
                       options: [("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
                                 ("ja", "Japanese"), ("ko", "Korean"), ("any", "Any")])
            // live preview — shows exactly what the options above produce (Android showPlayerSettings)
            SubtitlePreview()
        }
    }

    private var lookSection: some View {
        Section("Look & feel") {
            PrefToggle(label: "Titles under posters", key: "showTitles", def: true)
            PrefToggle(label: "Blur unwatched episode thumbnails", key: "blurUnwatched", def: false)
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink("Legal & About") { LegalView() }
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
        }
    }

    /// Android Addons.probe: fetch the manifest, validate it, take ITS name — nothing is added
    /// until the addon answers.
    private func addAddon() {
        var code = addonCode.trimmingCharacters(in: .whitespaces)
        if !code.hasPrefix("http") { code = "https://" + code }
        if code.hasSuffix("/manifest.json") { code = String(code.dropLast("/manifest.json".count)) }
        probing = true; addonMsg = ""
        Task {
            guard let m = try? await API.json("/manifest.json", base: code),
                  m["catalogs"] is [[String: Any]] || m["resources"] != nil else {
                addonMsg = "That code doesn't answer as an addon — check it and try again."
                probing = false; return
            }
            if let u = URL(string: code), let host = u.host {
                API.serviceBase = "https://" + host
            }
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Addon"
            if !session.addons.contains(where: { $0.url == code }) {
                session.addons.append(Addon(url: code, name: name))
                var st = session.state
                st["addons"] = session.addons.map { ["url": $0.url, "name": $0.name] }
                session.state = st
                session.push()
            }
            await session.detectLiveTv(); await session.checkAccess()
            addonMsg = "Added \(name)"
            addonCode = ""; probing = false
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
    @State private var name = ""
    @State private var avatar = "🍿"
    @State private var color = Profile.colors[0]
    private let avatars = ["🍿", "👑", "🦊", "🐼", "🦄", "🐯", "👻", "🤖", "🌸", "⚡️", "🎮", "🐶"]

    var body: some View {
        Form {
            HStack {
                Spacer()
                Text(avatar).font(.system(size: 44)).frame(width: 84, height: 84)
                    .background(Profile.tint(color), in: RoundedRectangle(cornerRadius: 18))
                Spacer()
            }
            TextField("Name", text: $name)
            // avatar AND color picker (Android addAvatarColorPicker) — the hue drives the tile everywhere
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))]) {
                ForEach(avatars, id: \.self) { a in
                    // buttons (not tap gestures) so the Siri Remote can focus them
                    Button { avatar = a } label: {
                        Text(a).font(.system(size: 32))
                            .frame(width: 48, height: 48)
                            .background(a == avatar ? Theme.accent.opacity(0.4) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                ForEach(Profile.colors, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Profile.tint(c)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white, lineWidth: c == color ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(profile == nil ? "Create" : "Save") {
                if let p = profile { session.renameProfile(p.id, name: name, avatar: avatar, color: color) }
                else { session.addProfile(name: name, avatar: avatar, color: color) }
                dismiss()
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            if let p = profile, session.profiles.count > 1 {
                Button("Delete profile", role: .destructive) {
                    session.deleteProfile(p.id); dismiss()
                }
            }
        }
        .navigationTitle(profile == nil ? "New profile" : "Edit profile")
        .onAppear {
            if let p = profile { name = p.name; avatar = p.avatar; if !p.color.isEmpty { color = p.color } }
            else { color = Profile.colors[session.profiles.count % Profile.colors.count] }
        }
    }
}


/// Live subtitle preview (Android showPlayerSettings preview box): exactly what the size /
/// background / outline / position prefs produce in the player.
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

/// Shelves picker (Android showShelfPicker): grouped pill chips — Movies then Shows — toggling
/// a catalog on/off the Home lineup. Order is kept; new picks append.
struct ShelfPickerView: View {
    @EnvironmentObject var session: Session
    private let cols = [GridItem(.adaptive(minimum: 120), spacing: 8)]
    var body: some View {
        let enabled = session.enabledShelves().map(\.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach([("movie", "Movies"), ("series", "Shows")], id: \.0) { t, title in
                    let cats = session.allShelves().filter { $0.type == t }
                    if !cats.isEmpty {
                        Text(title).font(.headline)
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(cats) { c in
                                let on = enabled.contains(c.id)
                                Button {
                                    var keys = enabled
                                    if on { keys.removeAll { $0 == c.id } } else { keys.append(c.id) }
                                    session.setShelves(keys)
                                } label: {
                                    Text((on ? "✓ " : "") + c.name).font(.caption)
                                        .lineLimit(1).frame(maxWidth: .infinity)
                                        .padding(.horizontal, 10).padding(.vertical, 8)
                                        .background(on ? Theme.accent : Theme.card, in: Capsule())
                                        .foregroundStyle(on ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button("Reset to default") { 
                    var ps = session.pstate(); ps["shelves"] = nil; session.setPstate(ps)
                }
                .font(.footnote).padding(.top, 8)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Shelves")
    }
}

/// Reorder screen (Android showShelfReorder): drag rows; saved with the debounced push.
struct ShelfReorderView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        List {
            #if os(tvOS)
            // no drag on the remote: move a shelf up / down with the buttons (Firestick reorder screen)
            let shelves = session.enabledShelves()
            ForEach(Array(shelves.enumerated()), id: \.element.id) { i, c in
                HStack {
                    Text(c.name); Spacer()
                    Text(c.type == "movie" ? "Movies" : "Shows").font(.caption).foregroundStyle(.secondary)
                    Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0)
                    Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == shelves.count - 1)
                }
            }
            #else
            ForEach(session.enabledShelves()) { c in
                HStack { Text(c.name); Spacer()
                    Text(c.type == "movie" ? "Movies" : "Shows").font(.caption).foregroundStyle(.secondary) }
            }
            .onMove { from, to in
                var keys = session.enabledShelves().map(\.id)
                keys.move(fromOffsets: from, toOffset: to)
                session.setShelves(keys)
            }
            #endif
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("Reorder shelves")
    }
}

extension ShelfReorderView {
    fileprivate func move(_ i: Int, by d: Int) {
        var keys = session.enabledShelves().map(\.id)
        let j = i + d
        guard keys.indices.contains(i), keys.indices.contains(j) else { return }
        keys.swapAt(i, j)
        session.setShelves(keys)
    }
}

/// Legal & About (Android showAbout / showTerms / showPrivacy, Legal.kt): the full Terms and
/// Privacy text reachable in-app (App Store review requirement), plus the version row.
struct LegalView: View {
    var body: some View {
        List {
            Section {
                HStack { BrandTitle(); Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundStyle(.secondary) }
                Text("Movies, shows and live TV — synced across your devices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Terms of Service") { LegalTextView(title: "Terms of Service", text: Legal.terms) }
                NavigationLink("Privacy Policy") { LegalTextView(title: "Privacy Policy", text: Legal.privacy) }
                Link("couchking.app", destination: URL(string: "https://couchking.app")!)
            }
        }
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
            Text("👑").font(.system(size: 56))
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
                Text("👑").font(.system(size: 36))
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
