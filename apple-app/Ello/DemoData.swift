import Foundation

/// Sample catalogue for screenshots and trying the app without a provider
/// (launch with the `-demo` argument). No artwork URLs: placeholders are drawn locally.
enum DemoData {
    struct Sample {
        let source: Source
        let channels: [Channel]
        let categories: [Category]
        let progress: [String: WatchItem]
        let profiles: [Profile]
    }

    static func make() -> Sample {
        let src = Source(id: "demo", name: "Demo", kind: .xtream, server: "http://demo", username: "demo")
        let liveNames = ["NPO 1", "NPO 2", "RTL 4", "SBS 6", "BBC One", "BBC Two", "ITV1", "Sky News", "CNN", "Eurosport 1",
                         "Discovery", "National Geographic", "Comedy Central", "Nickelodeon", "Disney Channel", "MTV",
                         "Ziggo Sport", "ESPN", "Fox", "HBO"]
        let movieNames = ["EN - The Glass Orchard (2024)", "EN - Northern Lights", "EN - Paper Comets", "EN - Harbor of Echoes",
                          "EN - The Long Night", "EN - Silver Coast", "EN - Midnight Express Line", "EN - A Quiet Storm",
                          "EN - Lanterns", "EN - The Last Summer", "EN - Crossings", "EN - Iron Valley"]
        let seriesNames = ["EN - Harbor Lights", "EN - The Wire Room", "EN - Ozark Falls", "EN - City of Glass",
                           "EN - Northern Stars", "EN - The Crown Jewels", "EN - Undertow", "EN - Homecoming"]
        var channels: [Channel] = []
        // Live categories: 0 NL, 1 UK, 2 Sports (NL), 3 Kids, 4 DE
        let liveGroup = [0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 1, 1, 1, 3, 3, 1, 2, 2, 4, 4]
        for (i, n) in liveNames.enumerated() {
            channels.append(Channel(id: "demo:live:\(i)", sourceId: "demo", kind: .live, providerId: "\(i)", name: n,
                                    group: "demo:live:\(liveGroup[i])", url: "", number: 101 + i, catchupDays: i < 8 ? 7 : nil))
        }
        for (i, n) in movieNames.enumerated() {
            channels.append(Channel(id: "demo:movie:\(i)", sourceId: "demo", kind: .movie, providerId: "\(i)", name: n,
                                    group: "demo:movie:\(i % 3)", url: "", rating: 6.5 + Double(i % 5) * 0.5,
                                    genre: ["Drama, Mystery", "Action, Thriller", "Comedy, Family"][i % 3],
                                    plot: "When a quiet town is shaken by an unexpected discovery, an unlikely group has one night to piece together the truth.",
                                    year: "\(2018 + i % 7)"))
        }
        for (i, n) in seriesNames.enumerated() {
            channels.append(Channel(id: "demo:series:\(i)", sourceId: "demo", kind: .series, providerId: "\(i)", name: n,
                                    group: "demo:series:\(i % 2)", url: "", rating: 7.8 + Double(i % 3) * 0.4,
                                    genre: "Crime, Drama", plot: "A gripping drama about family, loyalty and the price of secrets.",
                                    year: "\(2015 + i)", cast: "Lena Ortiz, Marcus Hale"))
        }
        let cats = [("NL | Algemeen", StreamKind.live), ("UK | Entertainment & News", .live), ("NL | Sport", .live),
                    ("Kids", .live), ("DE | Allgemein", .live),
                    ("New releases", .movie), ("Action", .movie), ("Family", .movie),
                    ("Drama series", .series), ("Crime", .series)]
        var categories: [Category] = []
        var counters: [StreamKind: Int] = [:]
        for (name, kind) in cats {
            let n = counters[kind, default: 0]
            counters[kind] = n + 1
            categories.append(Category(id: "demo:\(kind.rawValue):\(n)", name: name, kind: kind))
        }
        let progress: [String: WatchItem] = [
            "demo:movie:0": WatchItem(key: "demo:movie:0", title: "The Glass Orchard", poster: nil, url: "", channelId: "demo:movie:0",
                                      position: 2460, duration: 6060, updatedAt: Date()),
            "demo:ep:h-1-3": WatchItem(key: "demo:ep:h-1-3", title: "Harbor Lights", subtitle: "S1 E3 · Crossings", url: "",
                                       seriesId: "demo:series:0", position: 900, duration: 2600, updatedAt: Date().addingTimeInterval(-60))
        ]
        var me = Profile(id: "p1", name: "Me", color: 0x1A73E8)
        me.avatar = "art:panda"
        me.accent = "red"
        me.progress = progress
        me.favorites = ["demo:live:0", "demo:live:4", "demo:live:9"]
        me.recents = ["demo:live:4", "demo:live:0", "demo:live:7"]
        me.myList = [ListItem(key: "demo:series:1", title: "EN - The Wire Room", kind: .series, addedAt: Date()),
                     ListItem(key: "demo:movie:1", title: "EN - Northern Lights", kind: .movie, addedAt: Date())]
        var sam = Profile(id: "p2", name: "Sam", color: 0x188038)
        sam.avatar = "art:robo"
        var kids = Profile(id: "p3", name: "Kids", color: 0xE8710A, kids: true)
        kids.avatar = "art:fox"
        let profiles = [me, sam, kids]
        return Sample(source: src, channels: channels, categories: categories, progress: progress, profiles: profiles)
    }

    static func episodes(for show: Channel) -> [Episode] {
        let titles = ["Pilot", "The Long Night", "Crossings", "Undertow", "Lanterns", "Homecoming", "Tides", "Ashore"]
        return (1...2).flatMap { season in
            titles.enumerated().map { i, t in
                Episode(id: "\(show.providerId)-\(season)-\(i)", title: t, season: season, episode: i + 1, url: "",
                        plot: "The truth starts to surface.", duration: "00:4\(i):12")
            }
        }
    }

    static func guide(for channel: Channel) -> [Programme] {
        let shows = ["Morning News", "The Big Quiz", "Nature Walks", "Football Tonight", "City Stories", "Late Show",
                     "Weather", "Documentary: Oceans", "Film: Silver Coast", "Kitchen Heroes"]
        let cal = Calendar.current
        let now = Date()
        var start = cal.date(bySettingHour: cal.component(.hour, from: now), minute: 0, second: 0, of: now)!.addingTimeInterval(-4 * 3600)
        var out: [Programme] = []
        var i = Int(channel.providerId) ?? 0
        while start < now.addingTimeInterval(8 * 3600) {
            let len = Double([30, 60, 45, 90][i % 4]) * 60
            out.append(Programme(title: shows[i % shows.count], start: start, stop: start.addingTimeInterval(len),
                                 description: "An episode full of surprises.", hasArchive: channel.catchupDays != nil))
            start = start.addingTimeInterval(len)
            i += 1
        }
        return out
    }
}
