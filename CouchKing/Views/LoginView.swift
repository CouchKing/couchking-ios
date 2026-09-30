import SwiftUI

// The front door (Android showOnboarding → showSignIn / showSignUp / showForgotPassword):
// CouchKing logo + name, email + password, Sign in, Forgot password, Create account, and
// "Continue as guest" behind the Terms & Privacy acceptance every store requires.
// Shown on every cold start while nobody is signed in and nobody chose guest mode, and again
// after sign-out. `onDone` fires once the person is in (signed in or guest).
struct LoginView: View {
    @EnvironmentObject var session: Session
    var onDone: (() -> Void)? = nil
    enum Mode { case signIn, signUp, forgot }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var name = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var agreed = UserDefaults.standard.bool(forKey: "acceptedLegal")
    @State private var busy = false
    @State private var err = ""
    @State private var msg = ""
    @State private var legal: LegalDoc?

    struct LegalDoc: Identifiable { let id: String; let title: String; let text: String }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                BrandLockup(size: 96).padding(.top, 48).padding(.bottom, 4)
                switch mode {
                case .signIn: signInForm
                case .signUp: signUpForm
                case .forgot: forgotForm
                }
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $legal) { d in
            NavigationStack { LegalTextView(title: d.title, text: d.text) }
        }
    }

    // MARK: sign in (the Android showSignIn page, opened straight from the welcome)

    private var signInForm: some View {
        VStack(spacing: 12) {
            Text("Sign in").font(.title2.bold())
            Text("Welcome back — your library follows your account.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginField("Email", text: $email, kind: .email)
            LoginField("Password", text: $password, kind: .password)
            if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            LoginPill(busy ? "Signing in…" : "Sign in", disabled: busy) { gate { await signIn() } }
            LoginGhost("Forgot password?") { err = ""; mode = .forgot }
            LoginGhost("New here? Create account") { err = ""; mode = .signUp }
            LoginGhost("Continue as guest") {
                gate { session.setOnboarded(true); onDone?() }
            }
            terms
        }
    }

    // MARK: create account (showSignUp)

    private var signUpForm: some View {
        VStack(spacing: 12) {
            Text("Create account").font(.title2.bold())
            Text("One account, every device — your watchlist and history sync.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginField("Name", text: $name, kind: .name)
            LoginField("Email", text: $email, kind: .email)
            LoginField("Password (4+ characters)", text: $password, kind: .password)
            LoginField("Confirm password", text: $password2, kind: .password)
            if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            LoginPill(busy ? "Creating account…" : "Create account", disabled: busy) { gate { await signUp() } }
            LoginGhost("Already have an account? Sign in") { err = ""; mode = .signIn }
            terms
        }
    }

    // MARK: forgot password (showForgotPassword): email → 6-digit code (15 min) → new password

    private var forgotForm: some View {
        VStack(spacing: 12) {
            Text("Reset password").font(.title2.bold())
            Text("We'll email you a 6-digit code — it expires in 15 minutes.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginField("Email", text: $email, kind: .email)
            LoginPill(busy ? "Sending…" : "Email me the code", disabled: busy) {
                guard email.contains("@"), email.contains(".") else { err = "Enter a valid email"; return }
                err = ""; busy = true
                Task {
                    _ = await session.requestReset(email: email)
                    busy = false; codeSent = true
                    msg = "If that email has an account, the code is on its way"
                }
            }
            if !msg.isEmpty { Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if codeSent {
                LoginField("6-digit code", text: $code, kind: .code)
                LoginField("New password (4+ characters)", text: $password, kind: .password)
                LoginField("Confirm new password", text: $password2, kind: .password)
                if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                LoginPill(busy ? "Updating…" : "Set new password", disabled: busy) {
                    let c = code.trimmingCharacters(in: .whitespaces)
                    if c.count != 6 { err = "Enter the 6-digit code from the email"; return }
                    if password.count < 4 { err = "Password needs 4+ characters"; return }
                    if password != password2 { err = "Passwords don't match"; return }
                    err = ""; busy = true
                    Task {
                        let e = await session.resetPassword(email: email, code: c, password: password)
                        busy = false
                        if let e { err = e } else { onDone?() }
                    }
                }
            }
            LoginGhost("‹ Back") { err = ""; msg = ""; mode = .signIn }
        }
    }

    private var terms: some View {
        VStack(spacing: 6) {
            Button {
                agreed.toggle()
                UserDefaults.standard.set(agreed, forKey: "acceptedLegal")
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: agreed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(agreed ? Theme.accent : .secondary)
                    Text("I agree to the Terms & Conditions and Privacy Policy")
                        .font(.footnote).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 18) {
                Button("Terms & Conditions") { legal = LegalDoc(id: "t", title: "Terms of Service", text: Legal.terms) }
                Button("Privacy Policy") { legal = LegalDoc(id: "p", title: "Privacy Policy", text: Legal.privacy) }
            }
            .font(.footnote).foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    /// Everyone accepts once before entering (guests included) — Android gate().
    private func gate(_ go: @escaping () async -> Void) {
        guard agreed else { err = "Please accept the Terms & Privacy Policy to continue"; return }
        UserDefaults.standard.set(true, forKey: "acceptedLegal")
        err = ""
        Task { await go() }
    }

    private func signIn() async {
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            err = "Enter email and password"; return
        }
        busy = true
        let e = await session.signIn(email: email, password: password, create: false)
        busy = false
        if let e { err = e } else { onDone?() }
    }

    private func signUp() async {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { err = "Enter your name"; return }
        if !email.contains("@") || !email.contains(".") { err = "Enter a valid email"; return }
        if password.count < 4 { err = "Password needs 4+ characters"; return }
        if password != password2 { err = "Passwords don't match"; return }
        busy = true
        let e = await session.signIn(email: email, password: password, create: true, name: name)
        busy = false
        if let e { err = e } else { onDone?() }
    }
}

/// Logo + "CouchKing TV" wordmark (Android brandSpan: "Couch" purple, "King" white).
struct BrandLockup: View {
    var size: CGFloat = 96
    var body: some View {
        VStack(spacing: 10) {
            Image("Logo").resizable().aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            HStack(spacing: 0) {
                Text("Couch").foregroundStyle(Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0))
                Text("King TV").foregroundStyle(Color(red: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF5 / 255.0))
            }
            .font(.system(size: size * 0.3, weight: .bold))
            Text("Discover movies & shows — trailers, ratings, cast, where to watch, and your own watch tracker.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

/// Android `field`: card background, accent ring on focus.
struct LoginField: View {
    enum Kind { case email, password, name, code }
    let hint: String
    @Binding var text: String
    let kind: Kind
    @FocusState private var focused: Bool
    init(_ hint: String, text: Binding<String>, kind: Kind) { self.hint = hint; _text = text; self.kind = kind }
    var body: some View {
        Group {
            if kind == .password { SecureField(hint, text: $text) }
            else { TextField(hint, text: $text) }
        }
        .textFieldStyle(.plain)
        .focused($focused)
        #if os(iOS)
        .textInputAutocapitalization(kind == .name ? .words : .never)
        .autocorrectionDisabled()
        .keyboardType(kind == .email ? .emailAddress : (kind == .code ? .numberPad : .default))
        .textContentType(kind == .email ? .emailAddress : (kind == .password ? .password : (kind == .code ? .oneTimeCode : .name)))
        #endif
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.accent : .clear, lineWidth: 1.5))
    }
}

/// Android `pill`: the accent action.
struct LoginPill: View {
    let text: String
    var disabled = false
    let action: () -> Void
    init(_ text: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.text = text; self.disabled = disabled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(text).font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.7 : 1)
    }
}

/// Android `ghostPill`: #2C2649 secondary action.
struct LoginGhost: View {
    let text: String
    let action: () -> Void
    init(_ text: String, action: @escaping () -> Void) { self.text = text; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
