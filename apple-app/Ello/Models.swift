import Foundation

enum StreamKind: String, Codable, Hashable {
    case live, movie, series
}

/// An IPTV provider: an Xtream Codes login or an M3U playlist URL.
/// The password is kept in the Keychain, not here.
struct Source: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case xtream, m3u
        var id: String { rawValue }
        var label: String { self == .xtream ? "Xtream Codes" : "M3U playlist" }
    }

    var id: String = UUID().uuidString
    var name: String
    var kind: Kind
    /// Xtream: server address (http://host:port). M3U: playlist URL.
    var server: String
    var username: String = ""
}

struct Category: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: StreamKind
}

struct Channel: Codable, Identifiable, Hashable {
    /// "\(sourceId):\(kind):\(providerId)", same scheme as the Windows app.
    let id: String
    let sourceId: String
    let kind: StreamKind
    let providerId: String
    let name: String
    var logo: String?
    var group: String?
    /// Playable URL (empty for series: episodes have their own).
    var url: String
    var number: Int?
    var rating: Double?
    var genre: String?
    var plot: String?
    var year: String?
    var cast: String?
    var added: Double?
    /// Live channels the provider archives: days you can go back (catch-up).
    var catchupDays: Int?

    /// Title without provider prefixes like "EN - ".
    var cleanName: String {
        name.replacingOccurrences(of: #"^\s*\[?[A-Z]{2,3}\]?\s*[-|:•]\s*"#, with: "", options: .regularExpression)
    }
}

struct Episode: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let season: Int
    let episode: Int
    let url: String
    var thumb: String?
    var plot: String?
    var duration: String?
}

/// How far a movie or episode was watched (for Continue watching / resume).
struct WatchItem: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    var subtitle: String?
    var poster: String?
    let url: String
    var channelId: String?
    var seriesId: String?
    var position: Double
    var duration: Double
    var updatedAt: Date
    var finished: Bool { duration > 0 && position / duration >= 0.95 }
}

/// A TV guide entry.
struct Programme: Codable, Identifiable, Hashable {
    var id: String { "\(start.timeIntervalSince1970)-\(title)" }
    let title: String
    let start: Date
    let stop: Date
    var description: String?
    /// Server-local start ("yyyy-MM-dd HH:mm:ss") as the provider wrote it; used for catch-up URLs.
    var serverStart: String?
    var hasArchive: Bool = false
}

/// A movie or series saved to a profile's My List.
struct ListItem: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    let kind: StreamKind
    var poster: String?
    var group: String?
    var addedAt: Date
}

/// One person in the household (Netflix-style).
struct Profile: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var color: UInt32 = 0x1A73E8
    var emoji: String?
    /// Profile picture: "art:<id>" (one of ello's characters) or "photo" (uploaded).
    var avatar: String?
    /// Theme colour id (see `Theme.accents`).
    var accent: String?
    /// Only kids & family categories; never adult content.
    var kids = false
    var hideAdult = false
    var background = "default"
    var favorites: [String] = []
    var recents: [String] = []
    var myList: [ListItem] = []
    var progress: [String: WatchItem] = [:]
    /// Live TV: only these countries (empty = all). See `Country`.
    var countries: [String] = []
    var hiddenCategories: [String] = []
    var hiddenChannels: [String] = []
    var channelSort: ChannelSort = .provider

    init(id: String = UUID().uuidString, name: String, color: UInt32 = 0x1A73E8, emoji: String? = nil, kids: Bool = false, hideAdult: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.emoji = emoji
        self.kids = kids
        self.hideAdult = hideAdult
    }

    // Lenient decoding so profiles saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? 0x1A73E8
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        kids = try c.decodeIfPresent(Bool.self, forKey: .kids) ?? false
        hideAdult = try c.decodeIfPresent(Bool.self, forKey: .hideAdult) ?? false
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "default"
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        recents = try c.decodeIfPresent([String].self, forKey: .recents) ?? []
        myList = try c.decodeIfPresent([ListItem].self, forKey: .myList) ?? []
        progress = try c.decodeIfPresent([String: WatchItem].self, forKey: .progress) ?? [:]
        countries = try c.decodeIfPresent([String].self, forKey: .countries) ?? []
        hiddenCategories = try c.decodeIfPresent([String].self, forKey: .hiddenCategories) ?? []
        hiddenChannels = try c.decodeIfPresent([String].self, forKey: .hiddenChannels) ?? []
        channelSort = try c.decodeIfPresent(ChannelSort.self, forKey: .channelSort) ?? .provider
    }
}

/// The two layouts: big artwork and rows (cinema), or rounded tiles and cards (classic).
enum UITheme: String, Codable, CaseIterable, Identifiable {
    case cinema, classic
    var id: String { rawValue }
    var label: String { self == .cinema ? "Cinema" : "Classic" }
    var blurb: String {
        self == .cinema
            ? "Big artwork at the top, then rows of posters."
            : "Rounded tiles and cards with a light, airy layout."
    }
}

enum ChannelSort: String, Codable, CaseIterable, Identifiable {
    case provider, name, number
    var id: String { rawValue }
    var label: String {
        switch self {
        case .provider: return "Provider order"
        case .name: return "Name (A–Z)"
        case .number: return "Channel number"
        }
    }
}
