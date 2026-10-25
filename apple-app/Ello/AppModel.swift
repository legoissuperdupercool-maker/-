import Foundation
import Observation

/// App state: sources, the current source's catalogue (cached on the device),
/// profiles (each with favourites, history, Continue watching and My List).
@MainActor
@Observable
final class AppModel {
    var sources: [Source] = []
    var currentSourceId: String?

    /// What the active profile may see (Kids / hide-adult filtering applied).
    var live: [Channel] = []
    var movies: [Channel] = []
    var series: [Channel] = []
    var categories: [Category] = []
    /// Everything the provider has (before profile filtering).
    private var allChannels: [Channel] = []
    private var allCategories: [Category] = []

    var loading = false
    var status: String?
    var error: String?

    var profiles: [Profile] = []
    var activeProfileId: String?
    /// "Who's watching?" screen.
    var showProfilePicker = false

    /// Something to play full screen.
    var playing: PlayRequest?

    /// The look (Settings → Look), for everyone on this device.
    var uiTheme: UITheme = .theater {
        didSet {
            if !demo { defaults.set(uiTheme.rawValue, forKey: "uiTheme") }
            applyAccent()
        }
    }
    /// Bumped when the theme colour changes so views pick up `Theme.blue`.
    var accentVersion = 0

    let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    private let defaults = UserDefaults.standard
    private let cacheMaxAge: TimeInterval = 12 * 3600

    init() {
        if demo {
            let d = DemoData.make()
            sources = [d.source]
            currentSourceId = d.source.id
            profiles = d.profiles
            activeProfileId = d.profiles.first?.id
            allChannels = d.channels
            allCategories = d.categories
            refilter()
            showProfilePicker = ProcessInfo.processInfo.arguments.contains("picker")
            if ProcessInfo.processInfo.arguments.contains("classic") { uiTheme = .classic }
            return
        }
        if let data = defaults.data(forKey: "sources"), let list = try? JSONDecoder().decode([Source].self, from: data) {
            sources = list
        }
        currentSourceId = defaults.string(forKey: "currentSource") ?? sources.first?.id
        loadProfiles()
        uiTheme = UITheme(saved: defaults.string(forKey: "uiTheme"))
        showProfilePicker = profiles.count > 1
        applyAccent()
    }

    /// Point `Theme.blue` at the active profile's colour (or the look's own colour when the
    /// profile hasn't picked one), and `Theme.look` at the look.
    func applyAccent() {
        let hex = profile.accent == nil ? uiTheme.accent : Theme.accentValue(profile.accent)
        if hex != Theme.accentHex || Theme.look != uiTheme {
            Theme.accentHex = hex
            Theme.look = uiTheme
            accentVersion += 1
        }
    }

    var currentSource: Source? { sources.first { $0.id == currentSourceId } }

    func categories(_ kind: StreamKind) -> [Category] { categories.filter { $0.kind == kind } }

    func channel(_ id: String) -> Channel? {
        (live.first { $0.id == id }) ?? (movies.first { $0.id == id }) ?? (series.first { $0.id == id })
    }

    // MARK: profiles

    var profile: Profile {
        get { profiles.first { $0.id == activeProfileId } ?? profiles.first ?? Profile(name: "Me") }
        set {
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) { profiles[i] = newValue }
            persistProfiles()
        }
    }

    var progress: [String: WatchItem] {
        get { profile.progress }
        set {
            var p = profile
            p.progress = newValue
            profile = p
        }
    }

    private func loadProfiles() {
        if let data = defaults.data(forKey: "profiles"), let list = try? JSONDecoder().decode([Profile].self, from: data), !list.isEmpty {
            profiles = list
        } else {
            // First run with profiles: earlier watch progress becomes profile 1.
            var first = Profile(name: "Me")
            if let data = defaults.data(forKey: "progress"), let p = try? JSONDecoder().decode([String: WatchItem].self, from: data) {
                first.progress = p
            }
            profiles = [first]
        }
        activeProfileId = defaults.string(forKey: "activeProfile").flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? profiles.first?.id
    }

    private func persistProfiles() {
        guard !demo else { return }
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "profiles")
        defaults.set(activeProfileId, forKey: "activeProfile")
    }

    func selectProfile(_ id: String) {
        activeProfileId = id
        persistProfiles()
        refilter()
        showProfilePicker = false
    }

    func saveProfile(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            var merged = p
            // Keep data the editor doesn't touch.
            merged.favorites = profiles[i].favorites
            merged.recents = profiles[i].recents
            merged.myList = profiles[i].myList
            merged.progress = profiles[i].progress
            profiles[i] = merged
        } else {
            profiles.append(p)
        }
        persistProfiles()
        if p.id == activeProfileId { refilter() }
    }

    func deleteProfile(_ id: String) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Backdrop.photoURL(id))
        try? FileManager.default.removeItem(at: ProfilePhoto.url(id))
        if activeProfileId == id { activeProfileId = profiles.first?.id }
        persistProfiles()
        refilter()
    }

    // MARK: favourites, recents, My List

    func isFavorite(_ c: Channel) -> Bool { profile.favorites.contains(c.id) }

    func toggleFavorite(_ c: Channel) {
        var p = profile
        if let i = p.favorites.firstIndex(of: c.id) { p.favorites.remove(at: i) } else { p.favorites.append(c.id) }
        profile = p
    }

    var favoriteChannels: [Channel] { profile.favorites.compactMap { id in live.first { $0.id == id } } }
    var recentChannels: [Channel] { profile.recents.compactMap { id in live.first { $0.id == id } } }

    func inMyList(_ c: Channel) -> Bool { profile.myList.contains { $0.key == c.id } }

    func toggleMyList(_ c: Channel) {
        var p = profile
        if let i = p.myList.firstIndex(where: { $0.key == c.id }) {
            p.myList.remove(at: i)
        } else {
            p.myList.insert(ListItem(key: c.id, title: c.name, kind: c.kind, poster: c.logo, group: c.group, addedAt: Date()), at: 0)
        }
        profile = p
    }

    var myList: [Channel] {
        profile.myList.filter { $0.key.hasPrefix((currentSourceId ?? "") + ":") }.map { item in
            channel(item.key) ?? Channel(id: item.key, sourceId: currentSourceId ?? "", kind: item.kind,
                                         providerId: String(item.key.split(separator: ":").last ?? ""), name: item.title,
                                         logo: item.poster, group: item.group, url: "")
        }
    }

    /// Worked out again (off the main thread) only when the catalogue, My List or history
    /// changes; the last result shows meanwhile.
    var recs = Recommendations()
    @ObservationIgnored private var recSig = ""
    var recommendations: Recommendations {
        let p = profile
        let sig = "\(p.id)|\(shelfMovies.count)|\(shelfSeries.count)|\(p.myList.map(\.key).joined(separator: ","))|\(p.progress.count)|\(p.progress.values.filter(\.finished).count)"
        if sig != recSig {
            recSig = sig
            let candidates = shelfMovies + shelfSeries, cats = categories, all = live + movies + series
            Task {
                let value = await Task.detached(priority: .utility) {
                    let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    return Recommender.recommend(candidates: candidates, categories: cats, myList: p.myList,
                                                 history: Array(p.progress.values), channelLookup: { byId[$0] })
                }.value
                if sig == self.recSig { self.recs = value }
            }
        }
        return recs
    }

    // MARK: channel filters (countries, hidden, sort)

    /// Countries found in the live categories (and channel names), most channels first.
    var availableCountries: [CountryCount] {
        if let c = countryCache, c.count == allChannels.count { return c.value }
        let catCountry = Dictionary(allCategories.filter { $0.kind == .live }.map { ($0.id, Country.of(category: $0.name)) },
                                    uniquingKeysWith: { a, _ in a })
        var counts: [String: Int] = [:]
        for c in allChannels where c.kind == .live {
            let code = c.group.flatMap { catCountry[$0] ?? nil } ?? Country.of(channel: c.name) ?? Country.other
            counts[code, default: 0] += 1
        }
        let value = counts.map { CountryCount(code: $0.key, count: $0.value) }.sorted {
            if ($0.code == Country.other) != ($1.code == Country.other) { return $1.code == Country.other }
            return $0.count > $1.count
        }
        countryCache = (allChannels.count, value)
        return value
    }
    @ObservationIgnored private var countryCache: (count: Int, value: [CountryCount])?

    /// All live categories (also hidden ones), for the "Hide categories" screen.
    var allLiveCategories: [Category] { allCategories.filter { $0.kind == .live } }
    var hiddenChannelList: [Channel] {
        let ids = Set(profile.hiddenChannels)
        return allChannels.filter { ids.contains($0.id) }
    }

    func setCountries(_ codes: [String]) {
        var p = profile
        p.countries = codes
        profile = p
        refilter()
    }

    func toggleCountry(_ code: String) {
        var list = profile.countries
        if let i = list.firstIndex(of: code) { list.remove(at: i) } else { list.append(code) }
        setCountries(list)
    }

    func setCategoryHidden(_ id: String, _ hidden: Bool) {
        var p = profile
        p.hiddenCategories.removeAll { $0 == id }
        if hidden { p.hiddenCategories.append(id) }
        profile = p
        refilter()
    }

    func setChannelHidden(_ id: String, _ hidden: Bool) {
        var p = profile
        p.hiddenChannels.removeAll { $0 == id }
        if hidden { p.hiddenChannels.append(id) }
        profile = p
        refilter()
    }

    var channelSort: ChannelSort {
        get { profile.channelSort }
        set {
            var p = profile
            p.channelSort = newValue
            profile = p
            refilter()
        }
    }

    private func sorted(_ list: [Channel], _ sort: ChannelSort) -> [Channel] {
        switch sort {
        case .provider: return list
        case .name: return list.sorted { $0.cleanName.localizedStandardCompare($1.cleanName) == .orderedAscending }
        case .number: return list.sorted { ($0.number ?? .max) < ($1.number ?? .max) }
        }
    }

    // MARK: sources

    func save(_ source: Source, password: String) {
        if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i] = source } else { sources.append(source) }
        if source.kind == .xtream { Keychain.set(password, for: source.id) }
        persistSources()
        currentSourceId = source.id
        defaults.set(source.id, forKey: "currentSource")
        Task { await load(force: true) }
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        Keychain.delete(source.id)
        try? FileManager.default.removeItem(at: cacheURL(source.id))
        persistSources()
        if currentSourceId == source.id {
            currentSourceId = sources.first?.id
            apply([], [])
            Task { await load() }
        }
    }

    func select(_ id: String) {
        currentSourceId = id
        defaults.set(id, forKey: "currentSource")
        Task { await load() }
    }

    private func persistSources() {
        defaults.set(try? JSONEncoder().encode(sources), forKey: "sources")
    }

    /// Check a login before saving it.
    func test(_ source: Source, password: String) async -> String? {
        do {
            if source.kind == .xtream {
                try await XtreamClient(source: source, password: password).authenticate()
            } else {
                _ = try await M3UParser.load(source)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: catalogue

    private struct Cache: Codable {
        let channels: [Channel]
        let categories: [Category]
        let fetchedAt: Date
    }

    private func cacheURL(_ id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("catalog-\(id).json")
    }

    private func apply(_ channels: [Channel], _ cats: [Category]) {
        allChannels = channels
        allCategories = cats
        refilter()
    }

    /// Apply the active profile's Kids / hide-adult / country / movie filters to the lists.
    /// The work runs off the main thread (big catalogues froze the remote on Apple TV);
    /// the newest call wins.
    @ObservationIgnored private var filterGeneration = 0
    func refilter() {
        applyAccent()
        filterGeneration += 1
        let generation = filterGeneration
        let channels = allChannels, cats = allCategories, p = profile
        Task {
            let shown = await Task.detached(priority: .userInitiated) { AppModel.filtered(channels, cats, p) }.value
            guard generation == self.filterGeneration else { return }
            live = shown.live
            movies = shown.movies
            series = shown.series
            categories = shown.categories
            shelfMovies = shown.shelfMovies
            shelfSeries = shown.shelfSeries
            shelfLive = shown.shelfLive
        }
    }

    private struct Filtered {
        var live: [Channel], movies: [Channel], series: [Channel], categories: [Category]
        var shelfMovies: [Channel], shelfSeries: [Channel], shelfLive: [Channel]
    }

    nonisolated private static func filtered(_ channels: [Channel], _ cats: [Category], _ p: Profile) -> Filtered {
        let shown = ContentFilter.apply(channels: channels, categories: cats, profile: p)
        let sort = p.channelSort
        var live = shown.channels.filter { $0.kind == .live }
        switch sort {
        case .provider: break
        case .name: live.sort { $0.cleanName.localizedStandardCompare($1.cleanName) == .orderedAscending }
        case .number: live.sort { ($0.number ?? .max) < ($1.number ?? .max) }
        }
        let movies = shown.channels.filter { $0.kind == .movie }
        let series = shown.channels.filter { $0.kind == .series }
        let categories = sort == .name
            ? shown.categories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : shown.categories
        let adultLive = Set(categories.filter { $0.kind == .live && ContentFilter.matches(ContentFilter.adult, $0.name) }.map(\.id))
        return Filtered(
            live: live, movies: movies, series: series, categories: categories,
            shelfMovies: ContentFilter.shelf(movies, categories: categories, profile: p),
            shelfSeries: ContentFilter.shelf(series, categories: categories, profile: p),
            shelfLive: live.filter { c in !(c.group.map { adultLive.contains($0) } ?? false) && !ContentFilter.matches(ContentFilter.adult, c.name) }
        )
    }

    // MARK: movie & series filters

    /// Movies and series for Home, the rows and recommendations: without the profile's hidden
    /// countries/languages and categories. `movies` / `series` stay complete for search.
    var shelfMovies: [Channel] = []
    var shelfSeries: [Channel] = []
    /// Live channels for Home (no adult channels; they stay in Live TV).
    var shelfLive: [Channel] = []

    /// Countries and languages found in the movie and series lists, most titles first.
    var vodCountries: [CountryCount] { Self.countVodCountries(movies + series, categories) }

    nonisolated static func countVodCountries(_ list: [Channel], _ categories: [Category]) -> [CountryCount] {
        let catCountry = ContentFilter.categoryCountries(categories)
        var counts: [String: Int] = [:]
        var perGroup: [String: Int] = [:]
        var loose: [Channel] = []
        for c in list {
            if let g = c.group, catCountry[g] != nil { perGroup[g, default: 0] += 1 } else { loose.append(c) }
        }
        for (g, n) in perGroup { if let code = catCountry[g] { counts[code, default: 0] += n } }
        for c in loose { if let code = Country.of(channel: c.name) ?? Country.language(c.name) { counts[code, default: 0] += 1 } }
        return counts.map { CountryCount(code: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    func setVodCountryHidden(_ code: String, _ hidden: Bool) {
        var p = profile
        p.vodHiddenCountries.removeAll { $0 == code }
        if hidden { p.vodHiddenCountries.append(code) }
        profile = p
        refilter()
    }

    func setVodCategoryHidden(_ id: String, _ hidden: Bool) {
        var p = profile
        p.vodHiddenCategories.removeAll { $0 == id }
        if hidden { p.vodHiddenCategories.append(id) }
        profile = p
        refilter()
    }

    /// Show the cached catalogue at once; download it only when it's missing,
    /// older than 12 hours, or `force` is set.
    func load(force: Bool = false) async {
        guard !demo, let source = currentSource else { return }
        let url = cacheURL(source.id)
        var cachedAt: Date?
        // Reading a big catalogue takes a while: off the main thread.
        let cached = await Task.detached(priority: .userInitiated) { () -> Cache? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Cache.self, from: data)
        }.value
        if let cache = cached {
            apply(cache.channels, cache.categories)
            cachedAt = cache.fetchedAt
        }
        if !force, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheMaxAge { return }

        loading = cachedAt == nil
        error = nil
        status = cachedAt == nil ? "Loading channels, movies & series…" : nil
        do {
            let (channels, cats) = try await download(source) { [weak self] step in
                self?.status = step
            } onLive: { [weak self] live, cats in
                // Live TV is usable while movies and series still load.
                guard let self, cachedAt == nil, !live.isEmpty else { return }
                self.apply(live, cats)
                self.loading = false
            }
            apply(channels, cats)
            let cache = Cache(channels: channels, categories: cats, fetchedAt: Date())
            Task.detached(priority: .utility) { try? JSONEncoder().encode(cache).write(to: url) }
        } catch {
            if cachedAt == nil { self.error = error.localizedDescription }
        }
        loading = false
        status = nil
    }

    private func download(_ source: Source, step: (String) -> Void = { _ in },
                          onLive: ([Channel], [Category]) -> Void = { _, _ in }) async throws -> ([Channel], [Category]) {
        if source.kind == .m3u {
            step("Loading your playlist…")
            return try await M3UParser.load(source)
        }
        let client = XtreamClient(source: source, password: Keychain.get(source.id) ?? "")
        step("Signing in to your provider…")
        try await client.authenticate()
        step("Loading categories…")
        let cats = try await client.categories()
        // One list at a time: providers often allow only 1–2 connections.
        step("Loading live channels…")
        let l = (try? await client.live()) ?? []
        onLive(l, cats)
        step("Loading movies…")
        let m = (try? await client.movies()) ?? []
        step("Loading series…")
        let s = (try? await client.series()) ?? []
        if l.isEmpty && m.isEmpty && s.isEmpty { throw ProviderError.empty }
        return (l + m + s, cats)
    }

    private func client(for sourceId: String) -> XtreamClient? {
        guard let source = sources.first(where: { $0.id == sourceId }), source.kind == .xtream else { return nil }
        return XtreamClient(source: source, password: Keychain.get(source.id) ?? "")
    }

    /// Movie/series details from the provider, kept for the session.
    @ObservationIgnored private var infoCache: [String: MediaInfo] = [:]
    func details(for item: Channel) async -> MediaInfo? {
        if let cached = infoCache[item.id] { return cached }
        guard !demo, let client = client(for: item.sourceId), let info = try? await client.details(item.kind, id: item.providerId) else { return nil }
        infoCache[item.id] = info
        return info
    }

    func episodes(for show: Channel) async throws -> [Episode] {
        if demo { return DemoData.episodes(for: show) }
        return try await client(for: show.sourceId)?.episodes(seriesId: show.providerId) ?? []
    }

    /// TV guide for a channel (cached for 30 minutes).
    @ObservationIgnored private var guideCache: [String: (at: Date, items: [Programme])] = [:]
    func guide(for channel: Channel) async -> [Programme] {
        if demo { return DemoData.guide(for: channel) }
        if let hit = guideCache[channel.id], Date().timeIntervalSince(hit.at) < 1800 { return hit.items }
        let items = (try? await client(for: channel.sourceId)?.guide(streamId: channel.providerId)) ?? []
        guideCache[channel.id] = (Date(), items)
        return items
    }

    func canReplay(_ p: Programme, on c: Channel) -> Bool {
        guard let days = c.catchupDays, p.stop < Date() else { return false }
        return p.hasArchive || p.start > Date().addingTimeInterval(-Double(days) * 86400)
    }

    // MARK: playback & progress

    func play(_ channel: Channel) {
        if channel.kind == .live {
            var p = profile
            p.recents.removeAll { $0 == channel.id }
            p.recents.insert(channel.id, at: 0)
            p.recents = Array(p.recents.prefix(30))
            profile = p
        }
        playing = PlayRequest(
            key: channel.id, title: channel.cleanName, url: channel.url, poster: channel.logo,
            channelId: channel.id, isLive: channel.kind == .live
        )
    }

    func play(_ episode: Episode, of show: Channel) {
        playing = PlayRequest(
            key: "\(show.sourceId):ep:\(episode.id)", title: show.cleanName,
            subtitle: "S\(episode.season) E\(episode.episode) · \(episode.title)",
            url: episode.url, poster: episode.thumb ?? show.logo, seriesId: show.id, isLive: false
        )
    }

    func playCatchup(_ p: Programme, on c: Channel) {
        guard let url = client(for: c.sourceId)?.catchupURL(streamId: c.providerId, programme: p) else { return }
        playing = PlayRequest(key: "\(c.id):catchup:\(p.start.timeIntervalSince1970)", title: c.name,
                              subtitle: "\(p.title) (catch-up)", url: url, poster: c.logo, isLive: false)
    }

    func resume(_ item: WatchItem) {
        playing = PlayRequest(
            key: item.key, title: item.title, subtitle: item.subtitle, url: item.url, poster: item.poster,
            channelId: item.channelId, seriesId: item.seriesId, isLive: false
        )
    }

    func resumePosition(_ key: String) -> Double? {
        guard let p = progress[key], !p.finished, p.position > 30 else { return nil }
        return max(0, p.position - 3)
    }

    func saveProgress(_ req: PlayRequest, position: Double, duration: Double) {
        guard !req.isLive, !req.key.contains(":catchup:"), duration > 0, position > 0 else { return }
        var all = progress
        all[req.key] = WatchItem(
            key: req.key, title: req.title, subtitle: req.subtitle, poster: req.poster, url: req.url,
            channelId: req.channelId, seriesId: req.seriesId, position: position, duration: duration, updatedAt: Date()
        )
        if all.count > 300 {
            for old in all.values.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(all.count - 300) {
                all[old.key] = nil
            }
        }
        progress = all
    }

    var continueWatching: [WatchItem] {
        progress.values
            .filter { !$0.finished && $0.position > 30 && $0.key.hasPrefix((currentSourceId ?? "\u{0}") + ":") }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

struct PlayRequest: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    var subtitle: String?
    let url: String
    var poster: String?
    var channelId: String?
    var seriesId: String?
    let isLive: Bool
}

struct CountryCount: Hashable {
    let code: String
    let count: Int
}
