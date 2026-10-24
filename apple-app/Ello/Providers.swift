import Foundation

enum ProviderError: LocalizedError {
    case badAddress
    case login(String)
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .badAddress: return "That server address doesn’t look right. Use the form http://host:port."
        case .login(let m): return m
        case .http(let code):
            switch code {
            case 401, 403: return "Your provider refused the login (HTTP \(code)). Check the username and password."
            case 404: return "Nothing found at that address (HTTP 404). Check the server address."
            default: return "Your provider answered with an error (HTTP \(code))."
            }
        case .empty: return "Logged in, but the provider returned no channels, movies or series."
        }
    }
}

/// Loose JSON helpers: Xtream panels mix strings and numbers freely.
private func str(_ v: Any?) -> String? {
    switch v {
    case let s as String: return s.isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}
private func dbl(_ v: Any?) -> Double? { str(v).flatMap { Double($0) } }

/// Xtream sends guide titles base64-encoded (some panels don't).
private func decode64(_ s: String?) -> String? {
    guard let s else { return nil }
    if let data = Data(base64Encoded: s), let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
    return s
}

private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    cfg.timeoutIntervalForResource = 120
    cfg.httpAdditionalHeaders = ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]
    return URLSession(configuration: cfg)
}()

private func fetchData(_ url: URL) async throws -> Data {
    let (data, resp) = try await session.data(from: url)
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw ProviderError.http(http.statusCode)
    }
    return data
}

// MARK: - Xtream Codes

struct XtreamClient {
    let source: Source
    let password: String

    var base: String {
        var s = source.server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func api(_ action: String?, _ extra: [String: String] = [:]) throws -> URL {
        guard var c = URLComponents(string: base + "/player_api.php") else { throw ProviderError.badAddress }
        var items = [URLQueryItem(name: "username", value: source.username), URLQueryItem(name: "password", value: password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        guard let url = c.url else { throw ProviderError.badAddress }
        return url
    }

    private func json(_ action: String?, _ extra: [String: String] = [:]) async throws -> Any {
        let data = try await fetchData(try api(action, extra))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func rows(_ action: String) async throws -> [[String: Any]] {
        (try await json(action) as? [[String: Any]]) ?? []
    }

    private var enc: (String) -> String {
        { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
    }

    func authenticate() async throws {
        let obj = try await json(nil)
        guard let root = obj as? [String: Any], let info = root["user_info"] as? [String: Any] else {
            throw ProviderError.login("The server answered, but not like an Xtream Codes panel. Check the address.")
        }
        if str(info["auth"]) == "0" { throw ProviderError.login("Wrong username or password.") }
        if let status = str(info["status"]), status.lowercased() != "active" {
            throw ProviderError.login("Your subscription is \(status.lowercased()).")
        }
    }

    func categories() async throws -> [Category] {
        var out: [Category] = []
        for (action, kind) in [("get_live_categories", StreamKind.live), ("get_vod_categories", .movie), ("get_series_categories", .series)] {
            for r in (try? await rows(action)) ?? [] {
                if let id = str(r["category_id"]), let name = str(r["category_name"]) {
                    out.append(Category(id: "\(source.id):\(kind.rawValue):\(id)", name: name, kind: kind))
                }
            }
        }
        return out
    }

    func live() async throws -> [Channel] {
        try await rows("get_live_streams").compactMap { r in
            guard let id = str(r["stream_id"]), let name = str(r["name"]) else { return nil }
            // HLS (.m3u8): Apple's player can't play the raw .ts streams.
            return Channel(
                id: "\(source.id):live:\(id)", sourceId: source.id, kind: .live, providerId: id, name: name,
                logo: str(r["stream_icon"]),
                group: str(r["category_id"]).map { "\(source.id):live:\($0)" },
                url: "\(base)/live/\(enc(source.username))/\(enc(password))/\(id).m3u8",
                number: str(r["num"]).flatMap { Int($0) },
                catchupDays: str(r["tv_archive"]) == "1" ? (str(r["tv_archive_duration"]).flatMap { Int($0) } ?? 1) : nil
            )
        }
    }

    func movies() async throws -> [Channel] {
        try await rows("get_vod_streams").compactMap { r in
            guard let id = str(r["stream_id"]), let name = str(r["name"]) else { return nil }
            let ext = str(r["container_extension"]) ?? "mp4"
            return Channel(
                id: "\(source.id):movie:\(id)", sourceId: source.id, kind: .movie, providerId: id, name: name,
                logo: str(r["stream_icon"]) ?? str(r["cover"]),
                group: str(r["category_id"]).map { "\(source.id):movie:\($0)" },
                url: "\(base)/movie/\(enc(source.username))/\(enc(password))/\(id).\(ext)",
                rating: dbl(r["rating"]), genre: str(r["genre"]), plot: str(r["plot"]),
                year: str(r["year"]), added: dbl(r["added"])
            )
        }
    }

    func series() async throws -> [Channel] {
        try await rows("get_series").compactMap { r in
            guard let id = str(r["series_id"]), let name = str(r["name"]) else { return nil }
            let rating = dbl(r["rating"]) ?? dbl(r["rating_5based"]).map { $0 * 2 }
            return Channel(
                id: "\(source.id):series:\(id)", sourceId: source.id, kind: .series, providerId: id, name: name,
                logo: str(r["cover"]),
                group: str(r["category_id"]).map { "\(source.id):series:\($0)" },
                url: "", rating: rating, genre: str(r["genre"]), plot: str(r["plot"]),
                year: (str(r["releaseDate"]) ?? str(r["release_date"])).map { String($0.prefix(4)) },
                cast: str(r["cast"]), added: dbl(r["last_modified"])
            )
        }
    }

    /// TV guide for one channel: past (for catch-up), now and upcoming.
    func guide(streamId: String) async throws -> [Programme] {
        guard let root = try await json("get_simple_data_table", ["stream_id": streamId]) as? [String: Any],
              let rows = root["epg_listings"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let s = dbl(r["start_timestamp"]), let e = dbl(r["stop_timestamp"]) else { return nil }
            return Programme(
                title: decode64(str(r["title"])) ?? "Programme",
                start: Date(timeIntervalSince1970: s),
                stop: Date(timeIntervalSince1970: e),
                description: decode64(str(r["description"])),
                serverStart: str(r["start"]),
                hasArchive: str(r["has_archive"]) == "1"
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// Replay a past programme: Xtream's timeshift URL, with the start in the server's own clock.
    func catchupURL(streamId: String, programme: Programme) -> String? {
        guard let s = programme.serverStart, s.count >= 16 else { return nil }
        // "2026-10-23 20:30:00" -> "2026-10-23:20-30"
        let day = s.prefix(10)
        let hm = s.dropFirst(11).prefix(5).replacingOccurrences(of: ":", with: "-")
        let minutes = max(1, Int(programme.stop.timeIntervalSince(programme.start) / 60))
        return "\(base)/timeshift/\(enc(source.username))/\(enc(password))/\(minutes)/\(day):\(hm)/\(streamId).ts"
    }

    func episodes(seriesId: String) async throws -> [Episode] {
        guard let root = try await json("get_series_info", ["series_id": seriesId]) as? [String: Any] else { return [] }
        var out: [Episode] = []
        let seasons: [String: Any]
        if let dict = root["episodes"] as? [String: Any] {
            seasons = dict
        } else if let list = root["episodes"] as? [[Any]] {
            seasons = Dictionary(uniqueKeysWithValues: list.enumerated().map { (String($0.offset + 1), $0.element as Any) })
        } else {
            seasons = [:]
        }
        for (seasonKey, value) in seasons {
            for e in (value as? [[String: Any]]) ?? [] {
                guard let id = str(e["id"]) else { continue }
                let info = e["info"] as? [String: Any] ?? [:]
                let ext = str(e["container_extension"]) ?? "mp4"
                out.append(Episode(
                    id: id,
                    title: str(e["title"]) ?? "Episode",
                    season: Int(str(e["season"]) ?? seasonKey) ?? 1,
                    episode: Int(str(e["episode_num"]) ?? "") ?? 0,
                    url: "\(base)/series/\(enc(source.username))/\(enc(password))/\(id).\(ext)",
                    thumb: str(info["movie_image"]),
                    plot: str(info["plot"]),
                    duration: str(info["duration"])
                ))
            }
        }
        return out.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }
}

// MARK: - M3U

enum M3UParser {
    static func load(_ source: Source) async throws -> (channels: [Channel], categories: [Category]) {
        guard let url = URL(string: source.server.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProviderError.badAddress
        }
        let data = try await fetchData(url)
        let text = String(decoding: data, as: UTF8.self)
        var channels: [Channel] = []
        var groups: [String: StreamKind] = [:]
        var pending: [String: String] = [:]
        var pendingName = ""
        var n = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                pending = attributes(line)
                pendingName = line.components(separatedBy: ",").dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                n += 1
                let lower = line.lowercased()
                let kind: StreamKind = lower.contains("/movie/") ? .movie : lower.contains("/series/") ? .series : .live
                if kind == .series { continue } // episodes aren't grouped into shows in plain M3U
                let group = pending["group-title"]
                if let group { groups["\(source.id):\(kind.rawValue):\(group)"] = kind }
                channels.append(Channel(
                    id: "\(source.id):\(kind.rawValue):\(n)", sourceId: source.id, kind: kind, providerId: String(n),
                    name: pendingName.isEmpty ? (pending["tvg-name"] ?? "Channel \(n)") : pendingName,
                    logo: pending["tvg-logo"],
                    group: group.map { "\(source.id):\(kind.rawValue):\($0)" },
                    url: line
                ))
                pending = [:]
                pendingName = ""
            }
        }
        let categories = groups.map { key, kind in
            Category(id: key, name: String(key.split(separator: ":", maxSplits: 2).last ?? ""), kind: kind)
        }
        if channels.isEmpty { throw ProviderError.empty }
        return (channels, categories.sorted { $0.name < $1.name })
    }

    private static func attributes(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        let regex = try? NSRegularExpression(pattern: #"([a-zA-Z0-9-]+)="([^"]*)""#)
        let range = NSRange(line.startIndex..., in: line)
        regex?.enumerateMatches(in: line, range: range) { m, _, _ in
            guard let m, let k = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) else { return }
            out[String(line[k]).lowercased()] = String(line[v])
        }
        return out
    }
}
