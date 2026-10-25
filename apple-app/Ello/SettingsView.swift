import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Source?
    @State private var adding = RootView.startScreen == "add"
    @State private var editingProfile: Profile?
    @State private var showFilters = false
    @State private var showVodFilters = false
    @AppStorage("intro") private var introOn = true

    var body: some View {
        NavigationStack {
            List {
                Section("Look") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(UITheme.allCases) { t in
                                Button { model.uiTheme = t } label: { LookOption(theme: t, on: model.uiTheme == t).frame(width: 170) }
                                    .buttonStyle(.ello)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    Toggle("Logo animation at start", isOn: $introOn)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Colour for \(model.profile.name)").font(.system(size: 15)).foregroundStyle(Theme.dim)
                        HStack(spacing: 10) {
                            Button {
                                var p = model.profile
                                p.accent = nil
                                model.saveProfile(p)
                            } label: {
                                Text("Auto").font(.system(size: 12, weight: .bold))
                                    .frame(width: 42, height: 34)
                                    .background(Color(hex: model.uiTheme.accent).opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .foregroundStyle(.black)
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.white, lineWidth: model.profile.accent == nil ? 2.5 : 0).padding(-4))
                                    .padding(4)
                            }
                            .buttonStyle(.ello)
                            .accessibilityLabel("The look's own colour")
                            ForEach(Theme.accents, id: \.id) { a in
                                Button {
                                    var p = model.profile
                                    p.accent = a.id
                                    model.saveProfile(p)
                                } label: {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: a.hex)).frame(width: 34, height: 34)
                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(.white, lineWidth: model.profile.accent == a.id ? 2.5 : 0).padding(-4))
                                        .padding(4)
                                }
                                .buttonStyle(.ello)
                                .accessibilityLabel(a.name)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Sources") {
                    ForEach(model.sources) { s in
                        Button { editing = s } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.name).font(.system(size: 17, weight: .semibold))
                                    Text(s.kind.label).font(.system(size: 13)).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                if s.id == model.currentSourceId {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.blue)
                                }
                            }
                        }
                        .foregroundStyle(Theme.text)
                    }
                    .deletable { idx in idx.map { model.sources[$0] }.forEach(model.remove) }
                    Button { adding = true } label: { Label("Add source", systemImage: "plus.circle.fill") }
                }
                Section("Profiles") {
                    ForEach(model.profiles) { p in
                        Button { editingProfile = p } label: {
                            HStack(spacing: 12) {
                                Avatar(profile: p, size: 34)
                                Text(p.name)
                                if p.kids { Text("Kids").font(.system(size: 12, weight: .bold)).foregroundStyle(.yellow) }
                                Spacer()
                                if p.id == model.activeProfileId { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.blue) }
                            }
                        }
                        .foregroundStyle(Theme.text)
                    }
                    Button {
                        var p = Profile(name: "", color: Theme.profileColors[model.profiles.count % Theme.profileColors.count])
                        p.avatar = AvatarArt.free(model.profiles.map(\.avatar))
                        editingProfile = p
                    } label: {
                        Label("Add profile", systemImage: "person.badge.plus")
                    }
                    Button { dismiss(); model.showProfilePicker = true } label: { Label("Switch profile", systemImage: "person.2") }
                }
                Section {
                    Button { showFilters = true } label: { Label("Filter & hide channels", systemImage: "line.3.horizontal.decrease.circle") }
                } footer: {
                    Text("Only show the countries you watch, hide categories and channels, and sort A–Z. Saved per profile.")
                }
                Section {
                    Button { showVodFilters = true } label: { Label("Movies & series filters", systemImage: "film.stack") }
                } footer: {
                    Text("Hide countries, languages or categories (for example Persian films) from Home, the rows and recommendations. Search still finds everything. Saved per profile.")
                }
                Section {
                    Button { Task { await model.load(force: true) } } label: { Label("Reload channels, movies & series", systemImage: "arrow.clockwise") }
                        .disabled(model.currentSource == nil)
                }
                Section("VPN") {
                    Text("To hide your IP address, install the Mullvad (or any WireGuard) app from the App Store and switch it on. On iPad a VPN app covers every app, ello included, and Mullvad’s “Lockdown mode” blocks traffic if the VPN drops.")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Text("Your logins stay on this device (passwords in the Keychain). ello only talks to your IPTV provider. Recommendations are worked out on the iPad.")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                    Text("Video playback for MKV and other formats by VLC (MobileVLCKit, LGPL 2.1).")
                        .font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { SourceForm(source: nil) }
            .sheet(item: $editing) { s in SourceForm(source: s) }
            .fullScreenCover(item: $editingProfile) { p in ProfileEditor(profile: p) }
            .sheet(isPresented: $showFilters) { ChannelFilterView() }
            .sheet(isPresented: $showVodFilters) { VodFilterView() }
        }
        .preferredColorScheme(.dark)
    }
}

/// A small picture of each layout to choose from.
struct LookOption: View {
    let theme: UITheme
    let on: Bool

    private var previewBg: Color {
        switch theme {
        case .premium: return Color(hex: 0x0F171E)
        case .wonder: return Color(hex: 0x0B1238)
        case .glass: return Color(hex: 0x1C1F2A)
        default: return Color(hex: 0x0E0E0E)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(previewBg)
                if theme.isCinema {
                    VStack(spacing: 5) {
                        LinearGradient(colors: [previewBg, Color(hex: theme.accent).opacity(0.7)], startPoint: .leading, endPoint: .trailing)
                            .frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                        ForEach(0..<2, id: \.self) { _ in
                            HStack(spacing: 4) {
                                ForEach(0..<(theme.wideCards ? 3 : 6), id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: theme == .glass ? 5 : 2).fill(Color.white.opacity(0.22))
                                }
                            }
                            .frame(height: 18)
                        }
                    }
                    .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color.white.opacity(0.22)).frame(width: 80, height: 7)
                        ForEach(0..<2, id: \.self) { _ in
                            HStack(spacing: 6) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(Theme.blue.opacity(0.8)) } }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(height: 112)
            Text(theme.label).font(.system(size: 15, weight: .semibold))
            Text(theme.blurb).font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Theme.blue : .clear, lineWidth: 2.5))
    }
}

struct SourceForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: Source?

    @State private var kind: Source.Kind = .xtream
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Source.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Name (e.g. My IPTV)", text: $name)
                if kind == .xtream {
                    TextField("Server (http://host:port)", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } else {
                    TextField("Playlist URL (http://…/playlist.m3u)", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error {
                    Text(error).foregroundStyle(Theme.bad)
                }
                Section {
                    Text("Your password is stored in this device’s Keychain and only sent to your provider.")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
            .navigationTitle(source == nil ? "Add source" : "Edit source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if testing { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(server.isEmpty) }
                }
            }
            .onAppear {
                if let s = source {
                    kind = s.kind
                    name = s.name
                    server = s.server
                    username = s.username
                    password = Keychain.get(s.id) ?? ""
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() async {
        var s = source ?? Source(name: "", kind: kind, server: "")
        s.kind = kind
        s.name = name.isEmpty ? (kind == .xtream ? "My IPTV" : "Playlist") : name
        s.server = server
        s.username = username
        testing = true
        error = await model.test(s, password: password)
        testing = false
        if error == nil {
            model.save(s, password: password)
            dismiss()
        }
    }
}

/// Settings → Movies & series filters: countries/languages and categories to keep out of
/// Home, the rows and recommendations for this profile.
struct VodFilterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var countries: [CountryCount] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if countries.isEmpty {
                        Text("Your provider’s movie and series categories don’t name countries or languages.").foregroundStyle(Theme.dim)
                    }
                    ForEach(countries, id: \.code) { cc in
                        Toggle(isOn: Binding(
                            get: { !model.profile.vodHiddenCountries.contains(cc.code) },
                            set: { model.setVodCountryHidden(cc.code, !$0) }
                        )) {
                            HStack(spacing: 10) {
                                Text(Country.flag(cc.code))
                                Text(Country.label(cc.code))
                                Spacer()
                                Text("\(cc.count)").font(.system(size: 13)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                } header: {
                    Text("Countries & languages")
                } footer: {
                    Text("Switched off = hidden from Home, the Movies and Series rows and recommendations. Search still finds them.")
                }
                Section("Categories") {
                    ForEach(model.categories.filter { $0.kind != .live && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { cat in
                        Toggle(isOn: Binding(
                            get: { !model.profile.vodHiddenCategories.contains(cat.id) },
                            set: { model.setVodCategoryHidden(cat.id, !$0) }
                        )) {
                            HStack {
                                Text(cleanCategory(cat.name))
                                Spacer()
                                Text(cat.kind == .movie ? "Movies" : "Series").font(.system(size: 12)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a category")
            .navigationTitle("Movies & series")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                let list = model.movies + model.series, cats = model.categories
                countries = await Task.detached(priority: .userInitiated) { AppModel.countVodCountries(list, cats) }.value
            }
        }
        .preferredColorScheme(.dark)
    }
}
