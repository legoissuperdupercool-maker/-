import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var category: String? = nil
    @State private var query = ""
    @State private var showFilters = RootView.startScreen == "filters"
    @State private var catQuery = ""

    private static let favorites = "★fav"
    private static let recent = "★recent"

    private var shown: [Channel] {
        let base: [Channel]
        switch category {
        case .some(Self.favorites): base = model.favoriteChannels
        case .some(Self.recent): base = model.recentChannels
        case nil: base = model.live
        case let id?: base = model.live.filter { $0.group == id }
        }
        return query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var liveCategories: [Category] {
        let cats = model.categories(.live)
        return catQuery.isEmpty ? cats : cats.filter { $0.name.localizedCaseInsensitiveContains(catQuery) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 8) {
                if model.categories(.live).count > 12 {
                    SearchField(text: $catQuery, prompt: "Find a category").padding(.horizontal, 16)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        CategoryRow(name: "All channels", count: model.live.count, selected: category == nil) { category = nil }
                        if !model.favoriteChannels.isEmpty {
                            CategoryRow(name: "★ Favourites", count: model.favoriteChannels.count, selected: category == Self.favorites) { category = Self.favorites }
                        }
                        if !model.recentChannels.isEmpty {
                            CategoryRow(name: "Recently watched", count: nil, selected: category == Self.recent) { category = Self.recent }
                        }
                        ForEach(liveCategories) { cat in
                            CategoryRow(name: cat.name, count: nil, selected: category == cat.id) { category = cat.id }
                                .contextMenu {
                                    Button("Hide this category", systemImage: "eye.slash") {
                                        if category == cat.id { category = nil }
                                        model.setCategoryHidden(cat.id, true)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .frame(width: 270)

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    SearchField(text: $query, prompt: "Search channels")
                    Menu {
                        Picker("Sort", selection: Binding(get: { model.channelSort }, set: { model.channelSort = $0 })) {
                            ForEach(ChannelSort.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 17, weight: .semibold))
                            .frame(width: 46, height: 46).background(Theme.surface, in: Circle())
                    }
                    .tint(Theme.text)
                    Button { showFilters = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease")
                            Text(filterLabel).lineLimit(1)
                        }
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 16).frame(height: 46)
                        .background(model.profile.countries.isEmpty ? Theme.surface : Theme.blue.opacity(0.35), in: Capsule())
                    }
                    .foregroundStyle(Theme.text)
                }
                if !model.profile.countries.isEmpty || model.availableCountries.count > 1 {
                    CountryChips()
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                        ForEach(shown) { c in
                            ChannelCard(channel: c, favorite: model.isFavorite(c)) { model.play(c) }
                                .contextMenu { ChannelMenu(channel: c) }
                        }
                    }
                    .padding(.bottom, 30)
                    if shown.isEmpty {
                        Text(model.live.isEmpty && !model.profile.countries.isEmpty
                             ? "No channels for the countries you picked. Change them under Filter."
                             : "No channels here.")
                            .foregroundStyle(Theme.dim).padding(.top, 60)
                    }
                }
            }
            .padding(.trailing, 28)
        }
        .sheet(isPresented: $showFilters) { ChannelFilterView() }
    }

    private var filterLabel: String {
        let c = model.profile.countries
        let hidden = model.profile.hiddenCategories.count + model.profile.hiddenChannels.count
        if c.isEmpty { return hidden > 0 ? "Filter (\(hidden) hidden)" : "Filter" }
        return c.count <= 2 ? c.map { Country.flag($0) + " " + $0 }.joined(separator: ", ") : "\(c.count) countries"
    }
}

/// Quick country switches above the channel grid (the biggest countries first).
struct CountryChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.profile.countries
        let codes = Array(Set(selected + model.availableCountries.prefix(14).map(\.code)))
            .sorted { a, b in
                let ia = model.availableCountries.firstIndex { $0.code == a } ?? 999
                let ib = model.availableCountries.firstIndex { $0.code == b } ?? 999
                return ia < ib
            }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All countries", on: selected.isEmpty) { model.setCountries([]) }
                ForEach(codes, id: \.self) { code in
                    chip(code == Country.other ? "Other" : "\(Country.flag(code)) \(Country.label(code))", on: selected.contains(code)) {
                        model.toggleCountry(code)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title).font(.system(size: 14, weight: .medium)).padding(.horizontal, 14).frame(height: 34)
                .foregroundStyle(on ? Color.black : Theme.dim)
                .background(on ? Theme.text : Theme.surface, in: Capsule())
        }
        .buttonStyle(.ello)
    }
}

struct ChannelMenu: View {
    @Environment(AppModel.self) private var model
    let channel: Channel

    var body: some View {
        Button(model.isFavorite(channel) ? "Remove from favourites" : "Add to favourites",
               systemImage: model.isFavorite(channel) ? "star.slash" : "star") { model.toggleFavorite(channel) }
        Button("Hide channel", systemImage: "eye.slash") { model.setChannelHidden(channel.id, true) }
        if let g = channel.group {
            Button("Hide its category", systemImage: "rectangle.stack.badge.minus") { model.setCategoryHidden(g, true) }
        }
    }
}

/// Countries, hidden categories and hidden channels (per profile).
struct ChannelFilterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var catQuery = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { model.setCountries([]) } label: {
                        HStack {
                            Text("🌐  All countries")
                            Spacer()
                            if model.profile.countries.isEmpty { Image(systemName: "checkmark").foregroundStyle(Theme.blue) }
                        }
                    }
                    ForEach(model.availableCountries, id: \.self) { c in
                        Button { model.toggleCountry(c.code) } label: {
                            HStack {
                                Text("\(Country.flag(c.code))  \(Country.label(c.code))")
                                Spacer()
                                Text("\(c.count)").foregroundStyle(Theme.faint)
                                Image(systemName: model.profile.countries.contains(c.code) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.profile.countries.contains(c.code) ? Theme.blue : Theme.faint)
                            }
                        }
                    }
                } header: {
                    Text("Countries")
                } footer: {
                    Text("Pick one or more to only see their channels. ello reads the country from your provider’s category names (like “NL | Sport” or “UK: News”).")
                }

                Section("Sort channels") {
                    Picker("Order", selection: Binding(get: { model.channelSort }, set: { model.channelSort = $0 })) {
                        ForEach(ChannelSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    TextField("Find a category", text: $catQuery).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(model.allLiveCategories.filter { catQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(catQuery) }) { cat in
                        Toggle(cat.name, isOn: Binding(
                            get: { !model.profile.hiddenCategories.contains(cat.id) },
                            set: { model.setCategoryHidden(cat.id, !$0) }
                        ))
                    }
                } header: {
                    HStack {
                        Text("Categories")
                        Spacer()
                        if !model.profile.hiddenCategories.isEmpty {
                            Button("Show all") { model.profile.hiddenCategories.forEach { model.setCategoryHidden($0, false) } }
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                } footer: {
                    Text("Switch off categories you never watch. Long-press a channel or category in Live TV to hide it too.")
                }

                if !model.hiddenChannelList.isEmpty {
                    Section("Hidden channels") {
                        ForEach(model.hiddenChannelList) { c in
                            HStack {
                                Text(c.name)
                                Spacer()
                                Button("Show") { model.setChannelHidden(c.id, false) }.foregroundStyle(Theme.blue)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(Theme.text)
            .navigationTitle("Filter channels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct CategoryRow: View {
    let name: String
    let count: Int?
    let selected: Bool
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.faint) }
            }
            .font(.system(size: 15, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 14).frame(height: 40)
            .foregroundStyle(selected ? Color.black : Theme.dim)
            .background(selected ? Theme.text : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.ello)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
            TextField(prompt, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
            }
        }
        .padding(.horizontal, 16).frame(height: 46)
        .background(Theme.surface, in: Capsule())
    }
}
