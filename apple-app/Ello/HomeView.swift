import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @State private var detail: Channel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let hero = model.shelfMovies.first(where: { $0.plot != nil }) ?? model.shelfMovies.first {
                    HeroCard(channel: hero) { detail = hero }
                }
                if !model.continueWatching.isEmpty {
                    Rail(title: "Continue watching") {
                        ForEach(model.continueWatching) { item in
                            ContinueCard(item: item) { model.resume(item) }
                        }
                    }
                }
                if !model.favoriteChannels.isEmpty {
                    Rail(title: "Favourite channels", action: ("See all", { tab = .live })) {
                        ForEach(model.favoriteChannels) { c in
                            ChannelCard(channel: c, favorite: true) { model.play(c) }.contextMenu { ChannelMenu(channel: c) }
                        }
                    }
                }
                if !model.myList.isEmpty {
                    Rail(title: "My List") {
                        ForEach(model.myList) { c in PosterCard(channel: c) { detail = c } }
                    }
                }
                let recs = model.recommendations
                if !recs.forYou.isEmpty {
                    Rail(title: "Recommended for you") {
                        ForEach(recs.forYou) { c in PosterCard(channel: c) { detail = c } }
                    }
                }
                if let because = recs.because {
                    Rail(title: "Because you watched \(because.title)") {
                        ForEach(because.items) { c in PosterCard(channel: c) { detail = c } }
                    }
                }
                if !model.recentChannels.isEmpty {
                    Rail(title: "Recently watched channels") {
                        ForEach(model.recentChannels.prefix(16)) { c in
                            ChannelCard(channel: c, favorite: model.isFavorite(c)) { model.play(c) }.contextMenu { ChannelMenu(channel: c) }
                        }
                    }
                } else if !model.shelfLive.isEmpty {
                    Rail(title: "Live TV", action: ("See all", { tab = .live })) {
                        ForEach(model.shelfLive.prefix(16)) { c in
                            ChannelCard(channel: c, favorite: model.isFavorite(c)) { model.play(c) }.contextMenu { ChannelMenu(channel: c) }
                        }
                    }
                }
                if !model.shelfMovies.isEmpty {
                    Rail(title: "New movies", action: ("See all", { tab = .movies })) {
                        ForEach(newest(model.shelfMovies)) { c in
                            PosterCard(channel: c) { detail = c }
                        }
                    }
                }
                if !model.shelfSeries.isEmpty {
                    Rail(title: "Series", action: ("See all", { tab = .series })) {
                        ForEach(newest(model.shelfSeries)) { c in
                            PosterCard(channel: c) { detail = c }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(item: $detail) { c in DetailView(channel: c) }
    }

    private func newest(_ list: [Channel]) -> [Channel] {
        Array(list.sorted { ($0.added ?? 0) > ($1.added ?? 0) }.prefix(20))
    }
}

struct HeroCard: View {
    let channel: Channel
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 26) {
                Artwork(url: channel.logo, name: channel.name)
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 10) {
                    Text("FEATURED").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.blue).tracking(1.5)
                    Text(channel.cleanName).font(.system(size: 34, weight: .bold)).lineLimit(2)
                    Text([channel.year, channel.genre, channel.rating.map { String(format: "★ %.1f", $0) }].compactMap { $0 }.joined(separator: "  ·  "))
                        .foregroundStyle(Theme.dim)
                    if let plot = channel.plot {
                        Text(plot).foregroundStyle(Theme.dim).lineLimit(3).frame(maxWidth: 560, alignment: .leading)
                    }
                    Label("More info", systemImage: "info.circle.fill").font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(Theme.text, in: Capsule()).foregroundStyle(.black).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Theme.color(for: channel.name).opacity(0.55), Theme.surface], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 24)
            )
        }
        .buttonStyle(.ello)
        .padding(.horizontal, 28)
    }
}

/// Titled horizontal row.
struct Rail<Content: View>: View {
    let title: String
    var action: (String, () -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 21, weight: .semibold))
                Spacer()
                if let action {
                    Button(action.0, action: action.1).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.blue)
                }
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) { content() }.padding(.horizontal, 28)
            }
        }
    }
}

struct PosterCard: View {
    let channel: Channel
    var width: CGFloat = 150
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Artwork(url: channel.logo, name: channel.name)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(channel.cleanName).font(.system(size: 14, weight: .medium)).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.ello)
    }
}

struct ChannelCard: View {
    let channel: Channel
    var favorite = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Theme.surface2
                    Artwork(url: channel.logo, name: channel.name, contentMode: .fit).padding(18)
                    if let n = channel.number {
                        Text("\(n)").font(.system(size: 12, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule()).padding(8)
                    }
                    if favorite {
                        Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(.yellow)
                            .padding(7).background(.black.opacity(0.55), in: Circle()).padding(8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(width: 200, height: 112)
                Text(channel.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 12).frame(width: 200, height: 40, alignment: .leading)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.ello)
    }
}

struct ContinueCard: View {
    let item: WatchItem
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: item.poster, name: item.title).frame(width: 260, height: 146)
                    Rectangle().fill(Theme.blue).frame(width: 260 * min(1, item.position / max(1, item.duration)), height: 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(item.subtitle ?? "\(max(1, Int((item.duration - item.position) / 60))) min left")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                .padding(12).frame(width: 260, alignment: .leading)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.ello)
    }
}
