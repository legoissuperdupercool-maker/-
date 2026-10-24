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
    /// Movies & series: countries/languages and categories kept out of Home, the rows and
    /// recommendations (search still finds them).
    var vodHiddenCountries: [String] = []
    var vodHiddenCategories: [String] = []

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
        vodHiddenCountries = try c.decodeIfPresent([String].self, forKey: .vodHiddenCountries) ?? []
        vodHiddenCategories = try c.decodeIfPresent([String].self, forKey: .vodHiddenCategories) ?? []
    }
}

/// The app's looks (same as the Windows app). Theater, Premium, Wonder and Glass share the
/// cinema screens with their own design; Classic is the original rounded layout.
enum UITheme: String, Codable, CaseIterable, Identifiable {
    case theater, premium, wonder, glass, classic
    var id: String { rawValue }

    /// The saved setting ("cinema" was the old name for Theater).
    init(saved: String?) {
        self = saved == "cinema" ? .theater : UITheme(rawValue: saved ?? "") ?? .theater
    }

    var isCinema: Bool { self != .classic }
    /// Rows of wide 16:9 cards instead of posters.
    var wideCards: Bool { self == .premium || self == .wonder || self == .glass }

    var label: String {
        switch self {
        case .theater: return "Theater"
        case .premium: return "Premium"
        case .wonder: return "Wonder"
        case .glass: return "Glass"
        case .classic: return "Classic"
        }
    }
    var blurb: String {
        switch self {
        case .theater: return "Black, big artwork and rows of posters."
        case .premium: return "Deep slate, tabs along the top and wide cards."
        case .wonder: return "A starry blue night with glowing wide cards."
        case .glass: return "Frosted glass, a floating tab bar and rounded cards."
        case .classic: return "The original rounded tiles and cards."
        }
    }
    /// The look's own colour, used when the profile hasn't picked one.
    var accent: UInt32 {
        switch self {
        case .theater: return 0xE50914
        case .premium: return 0x00A8E1
        case .wonder: return 0x1F80E0
        case .glass: return 0xF5F5F7
        case .classic: return 0x4C8DFF
        }
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
