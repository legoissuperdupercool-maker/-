import Foundation

struct Recommendations {
    var forYou: [Channel] = []
    var because: (title: String, items: [Channel])?
}

/// On-device recommendations (same method as the Windows app; nothing leaves the
/// iPad). Each saved or watched title is a "seed"; candidates score on shared
/// genres, shared cast, and the same franchise ("Breaking Bad" → "El Camino: A
/// Breaking Bad Movie"; single common words never count), then on rating and
/// newness. Adult titles are never recommended, other-language copies are left
/// out, and titles listed several times (4K / HD) appear once.
enum Recommender {
    private struct Seed {
        let key: String
        let title: String
        let kind: StreamKind
        let genres: Set<String>
        let people: Set<String>
        let core: [String]
        let lang: String?
        var weight: Double
    }

    private struct Indexed {
        let c: Channel
        let core: [String]
        let coreKey: String
        let genres: Set<String>
        let people: Set<String>
        let lang: String?
        let adult: Bool
        let rating: Double
        let fresh: Double
    }

    private static let langAliases = ["US": "EN", "UK": "EN", "GB": "EN", "ENG": "EN", "AU": "EN", "CA": "EN", "IE": "EN"]
    private static let langPrefix = try! NSRegularExpression(pattern: #"^\s*\[?([A-Z]{2,3})\]?\s*[-|:•]"#)
    private static let langTag = try! NSRegularExpression(pattern: #"\((US|UK|GB|EN)\)\s*$"#, options: .caseInsensitive)

    private static func first(_ re: NSRegularExpression, _ s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).uppercased()
    }

    static func lang(_ text: String?) -> String? {
        guard let text, let code = first(langPrefix, text) ?? first(langTag, text) else { return nil }
        return langAliases[code] ?? code
    }

    private static let stop: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "to", "at", "for", "with", "from", "by", "part",
                                            "season", "vol", "hd", "fhd", "uhd", "4k", "sd", "multi", "sub", "subs", "dub", "movie",
                                            "film", "series", "us", "uk"]

    static func coreWords(_ title: String) -> [String] {
        var t = title.lowercased()
        t = t.replacingOccurrences(of: #"^\s*\[?[a-z]{2,3}\]?\s*[-|:•]\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\((?:19|20)\d{2}\)|\((?:us|uk|gb|en)\)|\b(?:19|20)\d{2}\b"#, with: " ", options: .regularExpression)
        return t.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII }).map(String.init)
            .filter { $0.count > 1 && !stop.contains($0) && Int($0) == nil }
    }

    static func cleanTitle(_ t: String) -> String {
        t.replacingOccurrences(of: #"^\s*\[?[A-Z]{2,3}\]?\s*[-|:•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\((?:19|20)\d{2}\)|\s*\((?:US|UK|GB|EN)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    private static let genreWords: [String: String] = [
        "action": "action", "adventure": "adventure", "animation": "animation", "animated": "animation", "anime": "animation",
        "cartoon": "animation", "comedy": "comedy", "comedies": "comedy", "crime": "crime", "documentary": "documentary",
        "documentaries": "documentary", "docu": "documentary", "drama": "drama", "dramas": "drama", "family": "family",
        "kids": "family", "children": "family", "fantasy": "fantasy", "history": "history", "historical": "history",
        "horror": "horror", "music": "music", "musical": "music", "mystery": "mystery", "romance": "romance", "romantic": "romance",
        "sci-fi": "scifi", "scifi": "scifi", "science": "scifi", "thriller": "thriller", "thrillers": "thriller",
        "suspense": "thriller", "war": "war", "western": "western", "reality": "reality", "sport": "sport", "sports": "sport",
        "biography": "biography", "biopic": "biography", "superhero": "action", "martial": "action", "soap": "drama"
    ]

    private static func genres(_ texts: String?...) -> Set<String> {
        var out = Set<String>()
        for t in texts.compactMap({ $0 }) {
            for w in t.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "-") }) {
                if let g = genreWords[String(w)] { out.insert(g) }
            }
        }
        return out
    }

    private static func people(_ texts: String?...) -> Set<String> {
        var out = Set<String>()
        for t in texts.compactMap({ $0 }) {
            for n in t.split(whereSeparator: { ",;/".contains($0) }).prefix(6) {
                let name = n.trimmingCharacters(in: .whitespaces).lowercased()
                if name.count > 3 && name.contains(" ") { out.insert(name) }
            }
        }
        return out
    }

    nonisolated(unsafe) private static var indexCache: (count: Int, firstId: String?, items: [Indexed])?

    private static func buildIndex(_ candidates: [Channel], _ categories: [Category]) -> [Indexed] {
        if let c = indexCache, c.count == candidates.count, c.firstId == candidates.first?.id { return c.items }
        let catName = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let now = Date().timeIntervalSince1970
        let items = candidates.filter { $0.kind != .live }.map { c -> Indexed in
            let cat = c.group.flatMap { catName[$0] }
            let core = coreWords(c.name)
            let age = c.added.map { (now - $0) / 86400 } ?? .infinity
            return Indexed(c: c, core: core, coreKey: "\(c.kind.rawValue):\(core.joined(separator: " "))",
                           genres: genres(c.genre, cat), people: people(c.cast), lang: lang(c.name) ?? lang(cat),
                           adult: ContentFilter.matches(ContentFilter.adult, c.name) || ContentFilter.matches(ContentFilter.adult, cat),
                           rating: min(10, c.rating ?? 0), fresh: age < 30 ? 1 : age < 120 ? 0.4 : 0)
        }
        indexCache = (candidates.count, candidates.first?.id, items)
        return items
    }

    private static func sameFranchise(_ seed: [String], _ cand: [String]) -> Bool {
        if seed.count < 2 && !(seed.count == 1 && seed[0].count >= 6) { return false }
        return " \(cand.joined(separator: " ")) ".contains(" \(seed.joined(separator: " ")) ")
    }

    private static func similarity(_ seed: Seed, _ it: Indexed) -> Double {
        var score = 0.0
        var related = false
        if sameFranchise(seed.core, it.core) { score += 12; related = true }
        let shared = it.genres.intersection(seed.genres).count
        if shared > 0 {
            score += 3 * Double(shared) + 4 * Double(shared) / Double(seed.genres.union(it.genres).count)
            related = related || shared >= min(2, seed.genres.count, it.genres.count)
        }
        let sharedPeople = it.people.intersection(seed.people).count
        if sharedPeople > 0 { score += 3 * Double(min(2, sharedPeople)); related = true }
        if !related { return 0 }
        if it.c.kind == seed.kind { score += 2 }
        return score
    }

    static func recommend(candidates: [Channel], categories: [Category], myList: [ListItem], history: [WatchItem],
                          channelLookup: (String) -> Channel?, limit: Int = 20) -> Recommendations {
        let index = buildIndex(candidates, categories)
        let byId = Dictionary(index.map { ($0.c.id, $0) }, uniquingKeysWith: { a, _ in a })

        var order: [String] = []
        var seeds: [String: Seed] = [:]
        func add(_ key: String, _ title: String, _ kind: StreamKind, _ weight: Double) {
            if seeds[key] != nil { seeds[key]!.weight += weight; return }
            let it = byId[key] ?? channelLookup(key).map { c in
                Indexed(c: c, core: coreWords(c.name), coreKey: "", genres: genres(c.genre), people: people(c.cast),
                        lang: lang(c.name), adult: false, rating: 0, fresh: 0)
            }
            seeds[key] = Seed(key: key, title: title, kind: kind, genres: it?.genres ?? [], people: it?.people ?? [],
                              core: coreWords(title), lang: it?.lang ?? lang(title), weight: weight)
            order.append(key)
        }
        for (n, h) in history.sorted(by: { $0.updatedAt > $1.updatedAt }).enumerated() {
            let w = (h.finished ? 2 : 1.2) * max(0.3, 1 - Double(n) * 0.04)
            if let sid = h.seriesId { add(sid, h.title, .series, w) } else { add(h.channelId ?? h.key, h.title, .movie, w) }
        }
        for (n, i) in myList.enumerated() { add(i.key, i.title, i.kind, 3 * max(0.5, 1 - Double(n) * 0.03)) }
        let seedList = order.compactMap { seeds[$0] }
        guard !seedList.isEmpty else { return Recommendations() }

        var langs: [String: Double] = [:]
        for s in seedList { if let l = s.lang { langs[l, default: 0] += s.weight } }
        let total = langs.values.reduce(0, +)
        let okLangs = Set(langs.filter { $0.value >= total * 0.2 }.map(\.key))
        let seedCores = Set(seedList.map { "\($0.kind.rawValue):\($0.core.joined(separator: " "))" })

        let eligible = index.filter { it in
            !it.adult && seeds[it.c.id] == nil && !seedCores.contains(it.coreKey) && !it.core.isEmpty
                && (okLangs.isEmpty || it.lang == nil || okLangs.contains(it.lang!))
        }

        func rank(_ score: (Indexed) -> Double, min minScore: Double) -> [Channel] {
            var scored: [(Indexed, Double)] = []
            for it in eligible {
                let s = score(it)
                if s >= minScore { scored.append((it, s + it.rating * 0.35 + it.fresh * 0.5)) }
            }
            scored.sort { $0.1 > $1.1 }
            var seen = Set<String>()
            var out: [Channel] = []
            for (it, _) in scored where !seen.contains(it.coreKey) {
                seen.insert(it.coreKey)
                out.append(it.c)
                if out.count >= limit { break }
            }
            return out
        }

        var result = Recommendations()
        if let anchor = seedList.first(where: { !$0.genres.isEmpty || !$0.people.isEmpty || $0.core.count >= 2 }) {
            let items = rank({ similarity(anchor, $0) }, min: 6)
            if items.count >= 4 { result.because = (cleanTitle(anchor.title), items) }
        }
        let shown = Set((result.because?.items ?? []).prefix(10).map(\.id))
        let norm = max(1, Double(seedList.count).squareRoot())
        result.forYou = rank({ it in
            if shown.contains(it.c.id) { return 0 }
            return seedList.reduce(0) { $0 + similarity($1, it) * $1.weight } / norm
        }, min: 6)
        return result
    }
}
