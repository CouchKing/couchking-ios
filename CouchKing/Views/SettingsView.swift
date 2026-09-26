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

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                if session.signedIn { profilesSection }
                addonsSection
                playerSection
                lookSection
                aboutSection
            }
            .navigationTitle("Settings")
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
                    .confirmationDialog("Delete account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            Task {
                                if !(await session.deleteAccount()) {
                                    err = "Couldn't delete — check your connection"
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently deletes your account and synced library on the server.")
                    }
                if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
            } else {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never)
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
                    HStack { Text(p.avatar); Text(p.name)
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
                Button("Switch profile") {
                    session.currentProfile = ""
                    UserDefaults.standard.set("", forKey: "curProfile")
                }
            }
        }
    }

    private var addonsSection: some View {
        Section("Addons") {
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
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add addon") { addAddon() }
                .disabled(addonCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var playerSection: some View {
        Section("Player") {
            PrefToggle(label: "Autoplay next episode", key: "autoplayNext", def: true)
            PrefPicker(label: "Skip step", key: "seekStep", def: 10,
                       options: [(10, "10s"), (15, "15s"), (30, "30s")])
            PrefPicker(label: "Subtitle size", key: "subScale", def: 1.0,
                       options: [(0.75, "Tiny"), (0.9, "Small"), (1.0, "Normal"), (1.3, "Large"), (1.6, "Huge")])
            PrefPicker(label: "Subtitle language", key: "subLang", def: "en",
                       options: [("en", "English"), ("es", "Spanish"), ("off", "Off")])
            PrefToggle(label: "Subtitle background", key: "subBg", def: true)
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
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            Link("Terms & Privacy", destination: URL(string: "https://couchking.app/terms")!)
        }
    }

    private func addAddon() {
        var code = addonCode.trimmingCharacters(in: .whitespaces)
        if !code.hasPrefix("http") { code = "https://" + code }
        if let u = URL(string: code), let host = u.host {
            API.serviceBase = "https://" + host
        }
        session.addons.append(Addon(url: code, name: "CouchKing"))
        var st = session.state
        st["addons"] = session.addons.map { ["url": $0.url, "name": $0.name] }
        session.state = st
        session.push()
        Task { await session.detectLiveTv(); await session.checkAccess() }
        addonCode = ""
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
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                Button("Email me the code") { sendCode() }
                    .disabled(!email.contains("@") || !email.contains("."))
            }
            if sent {
                Section {
                    TextField("6-digit code", text: $code).keyboardType(.numberPad)
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
    private let avatars = ["🍿", "👑", "🦊", "🐼", "🦄", "🐯", "👻", "🤖", "🌸", "⚡️", "🎮", "🐶"]

    var body: some View {
        Form {
            TextField("Name", text: $name)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))]) {
                ForEach(avatars, id: \.self) { a in
                    Text(a).font(.system(size: 32))
                        .frame(width: 48, height: 48)
                        .background(a == avatar ? Theme.accent.opacity(0.4) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { avatar = a }
                }
            }
            Button(profile == nil ? "Create" : "Save") {
                if let p = profile { session.renameProfile(p.id, name: name, avatar: avatar) }
                else { session.addProfile(name: name, avatar: avatar) }
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
        .onAppear { if let p = profile { name = p.name; avatar = p.avatar } }
    }
}
