import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: Session
    @State private var email = "", password = "", name = "", creating = false, err = ""
    @State private var addonCode = ""
    @AppStorage("showTitles") private var showTitles = true
    @AppStorage("blurUnwatched") private var blurUnwatched = false
    @AppStorage("autoplayNext") private var autoplayNext = true

    var body: some View {
        NavigationStack {
            Form {
                if session.signedIn {
                    Section("Account") {
                        LabeledContent("Signed in", value: session.email)
                        if session.profiles.count > 1 {
                            Button("Switch profile") {
                                session.currentProfile = ""
                                UserDefaults.standard.set("", forKey: "curProfile")
                            }
                        }
                        Button("Sign out", role: .destructive) {
                            session.email = ""; session.token = ""
                            UserDefaults.standard.removeObject(forKey: "email")
                            UserDefaults.standard.removeObject(forKey: "token")
                        }
                    }
                } else {
                    Section(creating ? "Create account" : "Sign in") {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                        if creating { TextField("Your name", text: $name) }
                        if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
                        Button(creating ? "Create" : "Sign in") {
                            Task { err = await session.signIn(email: email, password: password,
                                                             create: creating, name: name) ?? "" }
                        }
                        Button(creating ? "Have an account? Sign in" : "New here? Create one") {
                            creating.toggle()
                        }.font(.footnote)
                    }
                }
                Section("Addons") {
                    ForEach(session.addons) { a in Text(a.name) }
                    TextField("Access code", text: $addonCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add addon") { addAddon() }
                        .disabled(addonCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Playback & Look") {
                    Toggle("Titles under posters", isOn: $showTitles)
                    Toggle("Blur unwatched episode thumbnails", isOn: $blurUnwatched)
                    Toggle("Autoplay next episode", isOn: $autoplayNext)
                }
                Section {
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func addAddon() {
        var code = addonCode.trimmingCharacters(in: .whitespaces)
        if !code.hasPrefix("http") { code = "https://" + code }
        // The access code doubles as the service base (Android parity): the host part
        // becomes serviceBase for accounts/state; the full URL is the addon.
        if let u = URL(string: code), let host = u.host {
            API.serviceBase = "https://" + host
        }
        session.addons.append(Addon(url: code, name: "Addon"))
        var st = session.state
        st["addons"] = session.addons.map { ["url": $0.url, "name": $0.name] }
        session.state = st
        session.push()
        Task { await session.detectLiveTv(); await session.checkAccess() }
        addonCode = ""
    }
}
