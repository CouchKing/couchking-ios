#if os(tvOS) || os(macOS)
import SwiftUI

// Profiles on Apple TV + Mac.
// • Apple TV = the Firestick picker (MainActivity showProfilePicker ~805 / avatarView ~795 /
//   showProfileCreate / showProfileEdit): "Who's watching?" 28sp, one centered row of 92dp
//   face circles in the profile colour (emoji, else the initial) with the name under them, a
//   "＋ Add profile" circle (#241F3D, #4A4470 ring) while < 5, the cursor lands on the first
//   face, hold OK on a face = edit / remove.
// • Mac = the desktop profile manager (app.js profileManager ~2100, style.css .prof-card):
//   a 16px-radius card over a #000A scrim — "Profiles", one row per person (current = primary
//   button, others ghost) with ✎ and 🗑, "+ Add profile"; the edit view has name, the 24
//   avatar buttons, the 8 colour swatches, Save and ‹ Back.
// Both use the reference apps' shared avatar + colour choices (catalog.js AVATAR_CHOICES /
// COLOR_CHOICES); iPhone keeps its own picker.

#if os(tvOS)
enum ProfileRoute: Hashable { case create, edit(String) }

/// "Who's watching?" — the launch gate, and (with `onDone`) the rail's profile switcher.
struct TVWhoIsWatching: View {
    @EnvironmentObject var session: Session
    var onDone: (() -> Void)? = nil
    @Namespace private var ns
    @State private var path: [ProfileRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Text("Who's watching?").font(.system(size: TV.sp(28), weight: .bold)).foregroundStyle(.white)
                    .padding(.top, TV.dp(8)).padding(.bottom, TV.dp(6))
                Spacer().frame(height: TV.dp(26))
                HStack(spacing: 0) {
                    ForEach(Array(session.profiles.enumerated()), id: \.element.id) { i, p in
                        Button {
                            session.switchProfile(p.id)
                            session.push()
                            onDone?()
                        } label: { face(FaceCircle(profile: p, size: TV.dp(92)), p.name, dim: false) }
                        .buttonStyle(TVRingButton(radius: TV.dp(18)))
                        .prefersDefaultFocus(i == 0, in: ns)
                        .contextMenu {
                            Button("Edit profile") { path.append(.edit(p.id)) }
                            if session.profiles.count > 1 {
                                Button("Delete profile", role: .destructive) { session.deleteProfile(p.id) }
                            }
                        }
                    }
                    if session.profiles.count < 5 {
                        NavigationLink(value: ProfileRoute.create) {
                            face(Text("＋").font(.system(size: TV.sp(38))).foregroundStyle(TV.dim)
                                    .frame(width: TV.dp(92), height: TV.dp(92))
                                    .background(TV.card2, in: Circle())
                                    .overlay(Circle().stroke(TV.rgb(0x4A4470), lineWidth: TV.dp(2))),
                                 "Add profile", dim: true)
                        }
                        .buttonStyle(TVRingButton(radius: TV.dp(18)))
                    }
                }
                .focusSection()
                Text("Hold OK on a profile to edit or remove it.")
                    .font(.system(size: TV.sp(13))).foregroundStyle(TV.dim)
                    .padding(.top, TV.dp(10))
                Spacer()
            }
            .padding(.top, TV.dp(48)).padding(.horizontal, TV.dp(28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TV.bg.ignoresSafeArea())
            .focusScope(ns)
            .navigationDestination(for: ProfileRoute.self) { r in
                switch r {
                case .create: ProfileFormHub(profile: nil)
                case .edit(let id): ProfileFormHub(profile: session.profiles.first { $0.id == id })
                }
            }
        }
        // from the rail: Menu closes the switcher (a pushed create/edit page pops first)
        .onExitCommand(perform: path.isEmpty ? onDone : nil)
    }

    private func face<A: View>(_ avatar: A, _ name: String, dim: Bool) -> some View {
        VStack(spacing: 0) {
            avatar
            Text(name).font(.system(size: TV.sp(15))).foregroundStyle(dim ? TV.dim : .white)
                .lineLimit(1).padding(.top, TV.dp(8))
        }
        .padding(.horizontal, TV.dp(14)).padding(.top, TV.dp(14)).padding(.bottom, TV.dp(12))
    }
}
#endif

/// Create / edit (showProfileCreate / showProfileEdit on TV; the desktop card's edit view
/// reuses the same pickers): name, avatar choices, colour swatches, Save / Create, Delete.
struct ProfileFormHub: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let profile: Profile?
    /// First run (Android showProfileCreate(first = true)): the new profile becomes active and
    /// `onDone` continues to the shelves picker.
    var first = false
    var onDone: (() -> Void)? = nil
    @State private var name = ""
    @State private var avatar = ""
    @State private var color = ""

    var body: some View {
        HubPage(title: first ? "Create your profile" : (profile == nil ? "Add a profile" : "Edit profile"), root: first) {
            HubDim(text: profile == nil ? "Your watchlist, progress, and picks stay yours."
                                        : "Change the name, picture, or color — or remove this profile.")
            HubField(hint: "Name", text: $name)
            ProfilePickers(avatar: $avatar, color: $color)
            HubPill(text: first ? "Start watching" : (profile == nil ? "Create" : "Save")) { save() }
            if let p = profile, session.profiles.count > 1 {
                HubRow(label: "Delete profile") { session.deleteProfile(p.id); dismiss() }
            }
        }
        .onAppear {
            if let p = profile { name = p.name; avatar = p.avatar; color = p.color }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let p = profile { session.renameProfile(p.id, name: n, avatar: avatar, color: color) }
        else {
            let id = session.addProfile(name: n, avatar: avatar, color: color)
            if first, let id { session.switchProfile(id) }
        }
        if first { onDone?() } else { dismiss() }
    }
}

/// `.avatar-pick` + `.color-pick` (desktop) / addAvatarColorPicker (Firestick).
struct ProfilePickers: View {
    @Binding var avatar: String
    @Binding var color: String
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: TV.dp(8)) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(TV.dp(44)), spacing: TV.dp(6)), count: 12),
                      alignment: .leading, spacing: TV.dp(6)) {
                ForEach(ProfileChoices.avatars, id: \.self) { a in
                    Button { avatar = a } label: {
                        Text(a).font(.system(size: TV.sp(20))).frame(width: TV.dp(40), height: TV.dp(40))
                            .background(a == avatar ? TV.accent : TV.card2, in: RoundedRectangle(cornerRadius: TV.dp(10)))
                    }
                    .buttonStyle(TVRingButton(radius: TV.dp(10)))
                }
            }
            HStack(spacing: TV.dp(10)) {
                ForEach(ProfileChoices.colors, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Profile.tint(c)).frame(width: TV.dp(30), height: TV.dp(30))
                            .overlay(Circle().stroke(.white, lineWidth: c == color ? TV.dp(2) : 0))
                            .opacity(c == color ? 1 : 0.6)
                    }
                    .buttonStyle(TVRingButton(radius: TV.dp(15)))
                }
            }
        }
        .padding(.vertical, TV.dp(6))
        #else
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 6.4) {
                ForEach(ProfileChoices.avatars, id: \.self) { a in
                    Button { avatar = a } label: {
                        Text(a).font(.system(size: 20.8))
                            .padding(.horizontal, 9.6).padding(.vertical, 6.4)
                            .background(a == avatar ? Desk.accent : Desk.card2, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(ProfileChoices.colors, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Profile.tint(c)).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(c == color ? Color.white : .clear, lineWidth: 2))
                            .opacity(c == color ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        #endif
    }
}

#if os(macOS)
/// The desktop profile manager card. `gate` = launch "who's watching" (no scrim dismiss);
/// otherwise it's the rail's overlay and `onClose` removes it.
struct MacProfileManager: View {
    @EnvironmentObject var session: Session
    var gate = false
    var onClose: (() -> Void)? = nil
    @State private var editing: Profile?
    @State private var creating = false
    @State private var name = ""
    @State private var avatar = "👤"
    @State private var color = ""
    @State private var confirmDelete: Profile?

    var body: some View {
        ZStack {
            (gate ? Desk.bg : Color.black.opacity(0.67)).ignoresSafeArea()
                .onTapGesture { if !gate { onClose?() } }
            VStack(alignment: .leading, spacing: 12.8) {
                if editing != nil || creating { editView } else { listView }
            }
            .padding(22.4)
            .frame(minWidth: 340, alignment: .leading)
            .fixedSize()
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 16))
            if let p = confirmDelete {
                ConfirmCard(title: "Delete profile \"\(p.name)\"?", text: "Its watch history goes with it.", confirm: "Delete") {
                    let wasCurrent = p.id == session.currentProfile
                    session.deleteProfile(p.id)
                    if wasCurrent, let first = session.profiles.first { session.switchProfile(first.id) }
                    confirmDelete = nil
                } cancel: { confirmDelete = nil }
            }
        }
    }

    private var listView: some View {
        Group {
            Text("Profiles").font(.system(size: 18.7, weight: .bold)).foregroundStyle(Desk.fg)
            ForEach(session.profiles) { p in
                HStack(spacing: 9.6) {
                    Button { session.switchProfile(p.id); session.push(); onClose?() } label: {
                        Text((p.avatar.isEmpty ? "👤" : p.avatar) + "  " + p.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(DeskButton(kind: p.id == session.currentProfile ? .primary : .ghost))
                    Button("✎") { open(p) }.buttonStyle(DeskButton(kind: .ghost, small: true)).help("Edit")
                    if session.profiles.count > 1 {
                        Button("🗑") { confirmDelete = p }.buttonStyle(DeskButton(kind: .ghost, small: true)).help("Delete profile")
                    }
                }
            }
            if session.profiles.count < 5 {
                Button("+ Add profile") { open(nil) }.buttonStyle(DeskButton(kind: .ghost))
            }
        }
    }

    private var editView: some View {
        Group {
            Text(editing != nil ? "Edit profile" : "New profile").font(.system(size: 18.7, weight: .bold)).foregroundStyle(Desk.fg)
            DeskField(placeholder: "Name", text: $name)
            ProfilePickers(avatar: $avatar, color: $color)
            Button("Save") { save() }.buttonStyle(DeskButton(kind: .primary))
            Button("‹ Back") { editing = nil; creating = false }.buttonStyle(DeskButton(kind: .ghost))
        }
    }

    private func open(_ p: Profile?) {
        editing = p; creating = p == nil
        name = p?.name ?? ""; avatar = p?.avatar.isEmpty == false ? p!.avatar : "👤"; color = p?.color ?? ""
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let p = editing { session.renameProfile(p.id, name: n, avatar: avatar, color: color) }
        else { session.addProfile(name: n, avatar: avatar, color: color) }
        editing = nil; creating = false
    }
}
#endif
#endif
