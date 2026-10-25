import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// ello's drawn characters (same set as the Windows app). Images live in the
/// asset catalogue as "avatar-<id>".
enum AvatarArt {
    static let all: [(id: String, name: String)] = [
        ("sunny", "Sunny"), ("mochi", "Mochi"), ("robo", "Robo"), ("kitty", "Kitty"), ("bear", "Bear"), ("panda", "Panda"),
        ("fox", "Fox"), ("frog", "Frog"), ("ghost", "Ghost"), ("alien", "Zib"), ("monster", "Grub"), ("penguin", "Pip"),
        ("owl", "Hoot"), ("dino", "Rex"), ("cool", "Ace"), ("star", "Nova"), ("bunny", "Bun"), ("tiger", "Stripe")
    ]

    /// A character nobody else in the household has yet.
    static func free(_ used: [String?]) -> String {
        let taken = Set(used.compactMap { $0 })
        return "art:" + (all.first { !taken.contains("art:" + $0.id) }?.id ?? all[0].id)
    }

    /// Stable pick for profiles that never chose one.
    static func fallback(_ seed: String) -> String {
        var h: UInt32 = 0
        for u in seed.unicodeScalars { h = h &* 31 &+ u.value }
        return all[Int(h % UInt32(all.count))].id
    }
}

/// An uploaded profile picture, kept square and small in Documents.
enum ProfilePhoto {
    static func url(_ profileId: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar-\(profileId).jpg")
    }

    static func save(_ data: Data, for profileId: String) -> Bool {
        guard let img = UIImage(data: data) else { return false }
        let side = min(img.size.width, img.size.height)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let out = CGSize(width: 480, height: 480)
        let small = UIGraphicsImageRenderer(size: out).image { _ in
            img.draw(in: CGRect(x: -crop.minX * out.width / side, y: -crop.minY * out.height / side,
                                width: img.size.width * out.width / side, height: img.size.height * out.height / side))
        }
        guard let jpg = small.jpegData(compressionQuality: 0.88) else { return false }
        return (try? jpg.write(to: url(profileId))) != nil
    }
}

/// Rounded-square profile picture: a character, or the uploaded photo.
struct Avatar: View {
    let profile: Profile
    var size: CGFloat = 44
    var round = false
    /// Changes when a new photo is saved, so the picture reloads.
    var photoVersion = 0

    private var radius: CGFloat { round ? size / 2 : max(4, size * 0.12) }

    var body: some View {
        picture
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if profile.kids && size > 60 {
                    Text("KIDS").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.yellow, in: Capsule()).foregroundStyle(.black).padding(8)
                }
            }
    }

    @ViewBuilder private var picture: some View {
        if profile.avatar == "photo", let img = UIImage(contentsOfFile: ProfilePhoto.url(profile.id).path) {
            Image(uiImage: img).resizable().scaledToFill().id(photoVersion)
        } else {
            let id = profile.avatar.flatMap { $0.hasPrefix("art:") ? String($0.dropFirst(4)) : nil } ?? AvatarArt.fallback(profile.id)
            Image("avatar-\(id)").resizable().scaledToFill()
        }
    }
}

/// "Who's watching?": big pictures, names underneath, and a manage mode.
struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Profile?
    @State private var manage = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var tile: CGFloat { sizeClass == .compact ? 104 : 150 }

    var body: some View {
        ZStack {
            Theme.cinemaBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Wordmark(size: 26)
                    Spacer()
                }
                .padding(.horizontal, 32).padding(.top, 18)
                Spacer()
                Text(manage ? "Manage profiles" : "Who’s watching?")
                    .font(.system(size: sizeClass == .compact ? 30 : 46, weight: .medium))
                    .padding(.bottom, 34)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 26), count: columns), spacing: 26) {
                    ForEach(model.profiles) { p in
                        Button {
                            if manage { editing = p } else { model.selectProfile(p.id) }
                        } label: {
                            VStack(spacing: 12) {
                                Avatar(profile: p, size: tile)
                                    .overlay {
                                        if manage {
                                            RoundedRectangle(cornerRadius: tile * 0.12, style: .continuous).fill(.black.opacity(0.55))
                                            Image(systemName: "pencil").font(.system(size: tile * 0.28, weight: .semibold))
                                        }
                                    }
                                Text(p.name).font(.system(size: 17)).foregroundStyle(Color(hex: 0x808080)).lineLimit(1)
                            }
                        }
                        .buttonStyle(ProfileTileStyle())
                    }
                    if model.profiles.count < 8 {
                        Button {
                            var p = Profile(name: "", color: Theme.profileColors[model.profiles.count % Theme.profileColors.count])
                            p.avatar = AvatarArt.free(model.profiles.map(\.avatar))
                            editing = p
                        } label: {
                            VStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: tile * 0.12, style: .continuous)
                                    .strokeBorder(Color(hex: 0x555555), lineWidth: 2)
                                    .frame(width: tile, height: tile)
                                    .overlay(Image(systemName: "plus").font(.system(size: tile * 0.34, weight: .light)).foregroundStyle(Color(hex: 0x808080)))
                                Text("Add profile").font(.system(size: 17)).foregroundStyle(Color(hex: 0x808080))
                            }
                        }
                        .buttonStyle(ProfileTileStyle())
                    }
                }
                .padding(.horizontal, 20)
                Button { manage.toggle() } label: {
                    Text(manage ? "DONE" : "MANAGE PROFILES")
                        .font(.system(size: 16, weight: .medium)).tracking(2.5)
                        .padding(.horizontal, 26).frame(height: 46)
                        .foregroundStyle(manage ? .black : Color(hex: 0x808080))
                        .background(manage ? Color.white : .clear)
                        .overlay(Rectangle().strokeBorder(manage ? .white : Color(hex: 0x808080), lineWidth: 1))
                }
                .buttonStyle(.ello)
                .padding(.top, 46)
                Spacer()
                Spacer()
            }
        }
        .fullScreenCover(item: $editing) { p in ProfileEditor(profile: p, choosing: RootView.startScreen == "chooser") }
        .onAppear {
            // Screenshot runs: `-screen editor` / `-screen chooser`.
            if ["editor", "chooser"].contains(RootView.startScreen ?? "") { editing = model.profiles.first }
        }
    }

    private var columns: Int {
        let n = model.profiles.count + (model.profiles.count < 8 ? 1 : 0)
        return min(n, sizeClass == .compact ? 2 : 5)
    }
}

/// Pressed/focused tiles get a white ring around the picture.
struct ProfileTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration) }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                // Apple TV: the selected card grows with a glow (no white block).
                .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.1 : 1))
                .shadow(color: .black.opacity(focused ? 0.7 : 0), radius: 20, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// "ello. smartTV"
struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        Image("Wordmark").resizable().scaledToFit().frame(height: size * 1.3).accessibilityLabel("ello")
    }
}

/// Full-screen profile editor; the picture opens the chooser.
struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State var profile: Profile
    @State private var photo: PhotosPickerItem?
    @State private var confirmDelete = false
    @State var choosing = false
    @State private var photoVersion = 0

    private var isNew: Bool { !model.profiles.contains { $0.id == profile.id } }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        ZStack {
            Theme.cinemaBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isNew ? "Add profile" : "Edit profile").font(.system(size: compact ? 32 : 46, weight: .medium))
                        .padding(.bottom, 18)
                    Divider().overlay(Color(hex: 0x333333))
                    let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 22)) : AnyLayout(HStackLayout(alignment: .top, spacing: 26))
                    layout {
                        Button { choosing = true } label: {
                            Avatar(profile: profile, size: compact ? 120 : 150, photoVersion: photoVersion)
                                .overlay(alignment: .bottomLeading) {
                                    Image(systemName: "pencil").font(.system(size: 16, weight: .bold))
                                        .frame(width: 36, height: 36).background(.black.opacity(0.75), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                                        .padding(8)
                                }
                        }
                        .buttonStyle(.ello)
                        fields
                    }
                    .padding(.vertical, 22)
                    Divider().overlay(Color(hex: 0x333333))
                    HStack(spacing: 14) {
                        Button("Save") { save() }.buttonStyle(EditorButtonStyle(primary: true))
                        Button("Cancel") { dismiss() }.buttonStyle(EditorButtonStyle())
                        if !isNew && model.profiles.count > 1 {
                            Button("Delete profile") { confirmDelete = true }.buttonStyle(EditorButtonStyle())
                        }
                    }
                    .padding(.top, 26)
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, compact ? 20 : 40)
                .padding(.vertical, compact ? 24 : 50)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $choosing) {
            AvatarChooser(profile: profile, photoVersion: photoVersion) { avatar, version in
                profile.avatar = avatar
                photoVersion = version
            }
        }
        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteProfile(profile.id)
                dismiss()
            }
        } message: { Text("Their My List, favourites and watch history are removed from this device.") }
        .onChange(of: photo) {
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self), Backdrop.savePhoto(data, for: profile.id) {
                    profile.background = "photo"
                }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $profile.name)
                .font(.system(size: 20))
                .padding(.horizontal, 14).frame(height: 50)
                .background(Color(hex: 0x666666))
                .textInputAutocapitalization(.words)

            label("Theme colour")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Theme.accents, id: \.id) { a in
                        Button { profile.accent = a.id } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: a.hex))
                                .frame(width: 42, height: 42)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white, lineWidth: Theme.accentValue(profile.accent) == a.hex ? 3 : 0).padding(-4))
                                .padding(4)
                        }
                        .buttonStyle(.ello)
                        .accessibilityLabel(a.name)
                    }
                }
            }

            label("Background")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Backdrop.presets) { b in
                        Button { profile.background = b.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                b.view.frame(width: 86, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(profile.background == b.id ? .white : .white.opacity(0.12), lineWidth: profile.background == b.id ? 3 : 1))
                                Text(b.name).font(.system(size: 12)).foregroundStyle(profile.background == b.id ? .white : Theme.dim)
                            }
                        }
                        .buttonStyle(.ello)
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)).frame(width: 86, height: 52)
                                .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(profile.background == "photo" ? .white : .white.opacity(0.12), lineWidth: profile.background == "photo" ? 3 : 1))
                            Text(profile.background == "photo" ? "Change photo" : "Your photo").font(.system(size: 12)).foregroundStyle(Theme.dim)
                        }
                    }
                    .buttonStyle(.ello)
                }
                .padding(.vertical, 4)
            }

            label("Viewing")
            Toggle(isOn: $profile.kids) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kids profile").font(.system(size: 16, weight: .semibold))
                    Text("Only kids & family categories. Adult content is always hidden.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
            .tint(Theme.blue)
            Toggle(isOn: Binding(get: { profile.kids || profile.hideAdult }, set: { profile.hideAdult = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide adult content").font(.system(size: 16, weight: .semibold))
                    Text("Leaves out adult categories and titles everywhere.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
            .tint(Theme.blue)
            .disabled(profile.kids)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.dim).padding(.top, 10)
    }

    private func save() {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        if p.name.isEmpty { p.name = p.kids ? "Kids" : "Profile \(model.profiles.count + 1)" }
        if p.avatar == nil { p.avatar = "art:" + AvatarArt.fallback(p.id) }
        model.saveProfile(p)
        dismiss()
    }
}

/// Big white / outlined buttons at the bottom of the editor.
struct EditorButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .tracking(1)
            .padding(.horizontal, 26).frame(height: 46)
            .foregroundStyle(primary ? Color.black : Color(hex: 0x999999))
            .background(primary ? (configuration.isPressed ? Theme.blue : Color.white) : Color.clear)
            .overlay(Rectangle().strokeBorder(primary ? .clear : Color(hex: 0x777777), lineWidth: 1))
    }
}

/// "Choose a profile picture": the characters, or your own photo.
struct AvatarChooser: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    let profile: Profile
    let photoVersion: Int
    let onPick: (String, Int) -> Void
    @State private var photo: PhotosPickerItem?
    @State private var failed = false

    private var tile: CGFloat { sizeClass == .compact ? 96 : 128 }
    private var current: String { profile.avatar ?? "art:" + AvatarArt.fallback(profile.id) }

    var body: some View {
        ZStack {
            Theme.cinemaBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: {
                        Image(systemName: "arrow.left").font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.ello)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a profile picture").font(.system(size: sizeClass == .compact ? 22 : 30, weight: .medium))
                        Text("for \(profile.name.isEmpty ? "New profile" : profile.name)").font(.system(size: 15)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Avatar(profile: profile, size: 56, photoVersion: photoVersion)
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                Divider().overlay(Color(hex: 0x2A2A2A))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your own picture").font(.system(size: 19, weight: .semibold))
                        HStack(spacing: 14) {
                            PhotosPicker(selection: $photo, matching: .images) {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.badge.plus").font(.system(size: 30))
                                    Text("Upload a photo").font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(Theme.text)
                                .frame(width: tile, height: tile)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: tile * 0.12, style: .continuous))
                            }
                            .buttonStyle(.ello)
                            if current == "photo" {
                                Avatar(profile: profile, size: tile, photoVersion: photoVersion)
                                    .overlay(RoundedRectangle(cornerRadius: tile * 0.12 + 4, style: .continuous).strokeBorder(Theme.blue, lineWidth: 3).padding(-4))
                            }
                        }
                        if failed { Text("Couldn’t use that picture.").foregroundStyle(Theme.bad) }
                        Text("The ello crew").font(.system(size: 19, weight: .semibold)).padding(.top, 14)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(AvatarArt.all, id: \.id) { a in
                                Button {
                                    onPick("art:" + a.id, photoVersion)
                                    dismiss()
                                } label: {
                                    Image("avatar-\(a.id)").resizable().scaledToFill()
                                        .frame(width: tile, height: tile)
                                        .clipShape(RoundedRectangle(cornerRadius: tile * 0.12, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: tile * 0.12 + 4, style: .continuous)
                                            .strokeBorder(Theme.blue, lineWidth: current == "art:" + a.id ? 3 : 0).padding(-4))
                                }
                                .buttonStyle(ProfileTileStyle())
                                .accessibilityLabel(a.name)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: photo) {
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self), ProfilePhoto.save(data, for: profile.id) {
                    onPick("photo", photoVersion + 1)
                    dismiss()
                } else {
                    failed = true
                }
            }
        }
    }
}

/// Profile backgrounds: calm gradients, or a photo from the library.
struct Backdrop: Identifiable {
    let id: String
    let name: String
    let colors: [UInt32]

    static let presets: [Backdrop] = [
        Backdrop(id: "default", name: "ello", colors: [0x0E1013, 0x0E1013]),
        Backdrop(id: "aurora", name: "Aurora", colors: [0x0B3D3A, 0x1B1446]),
        Backdrop(id: "sunset", name: "Sunset", colors: [0x4A1730, 0x1A1030]),
        Backdrop(id: "ocean", name: "Ocean", colors: [0x0A2A4A, 0x06121F]),
        Backdrop(id: "forest", name: "Forest", colors: [0x13331D, 0x0B140E]),
        Backdrop(id: "ember", name: "Ember", colors: [0x4A2408, 0x140B06]),
        Backdrop(id: "violet", name: "Violet", colors: [0x2E1A52, 0x0F0A1A]),
        Backdrop(id: "slate", name: "Slate", colors: [0x2A2F38, 0x111317])
    ]

    @ViewBuilder var view: some View {
        if id == "default" {
            Theme.background
        } else {
            LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static func photoURL(_ profileId: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("background-\(profileId).jpg")
    }

    static func savePhoto(_ data: Data, for profileId: String) -> Bool {
        guard let img = UIImage(data: data) else { return false }
        // Scale down: a background doesn't need 48 megapixels.
        let scale = min(1, 2400 / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = small.jpegData(compressionQuality: 0.85) else { return false }
        return (try? jpg.write(to: photoURL(profileId))) != nil
    }
}

/// The active profile's background behind every screen.
struct AppBackground: View {
    let profile: Profile

    var body: some View {
        ZStack {
            if profile.background == "photo", let img = UIImage(contentsOfFile: Backdrop.photoURL(profile.id).path) {
                GeometryReader { geo in
                    Image(uiImage: img).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            } else {
                (Backdrop.presets.first { $0.id == profile.background } ?? Backdrop.presets[0]).view
            }
        }
        .ignoresSafeArea()
    }
}
