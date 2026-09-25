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

    private var accountSection: some View {
        Section("Account") {
            if session.signedIn {
                LabeledContent("Signed in", value: session.email)
                Button("Sign out", role: .destructive) {
                    session.email = ""; session.token = ""
                    UserDefaults.standard.removeObject(forKey: "email")
                    UserDefaults.standard.removeObject(forKey: "token")
                }
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
