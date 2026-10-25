import SwiftUI

/// Movies or Series: search, category filter and a poster grid.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let kind: StreamKind
    @State private var query = ""
    @State private var category: String? = nil
    @State private var detail: Channel?

    private var all: [Channel] { kind == .movie ? model.movies : model.series }
    private var shown: [Channel] {
        all.filter { c in
            (category == nil || c.group == category) && (query.isEmpty || c.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: kind == .movie ? "Search movies" : "Search series").frame(maxWidth: 520)
                Menu {
                    Button("All categories") { category = nil }
                    ForEach(model.categories(kind)) { cat in Button(cat.name) { category = cat.id } }
                } label: {
                    HStack {
                        Text(model.categories(kind).first { $0.id == category }?.name ?? "All categories").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 18).frame(height: 46)
                    .background(Theme.surface, in: Capsule())
                }
                .tint(Theme.text)
                Spacer()
                Text("\(shown.count) titles").foregroundStyle(Theme.faint).font(.system(size: 14))
            }
            .padding(.horizontal, 28)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 22) {
                    ForEach(shown) { c in
                        PosterCard(channel: c) { detail = c }
                            .contextMenu {
                                Button(model.inMyList(c) ? "Remove from My List" : "Add to My List",
                                       systemImage: model.inMyList(c) ? "minus" : "plus") { model.toggleMyList(c) }
                            }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 30)
            }
        }
        .sheet(item: $detail) { c in DetailView(channel: c) }
    }
}

/// Movie or series page: artwork, info, Play / Resume, and episodes for series.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let channel: Channel
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var loadingEpisodes = false
    @State private var error: String?
    /// Plot, cast and artwork from the provider (movie lists usually leave them out).
    @State private var info: MediaInfo?

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    private var meta: String {
        let year = info?.year ?? channel.year
        let genre = info?.genre ?? channel.genre
        let rating = (info?.rating ?? channel.rating).map { String(format: "★ %.1f", $0) }
        return [year, genre, info?.duration, rating].compactMap { $0 }.joined(separator: "  ·  ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 26) {
                    Artwork(url: channel.logo ?? info?.poster, name: channel.name)
                        .frame(width: 200, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(channel.cleanName).font(.system(size: 32, weight: .bold))
                        Text(meta).foregroundStyle(Theme.dim)
                        HStack(spacing: 12) {
                            actions
                            Button { model.toggleMyList(channel) } label: {
                                Label("My List", systemImage: model.inMyList(channel) ? "checkmark" : "plus")
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                        .padding(.vertical, 6)
                        if let plot = info?.plot ?? channel.plot {
                            Text(plot).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        } else if info == nil && !model.demo {
                            ProgressView().tint(Theme.dim)
                        }
                        if let cast = info?.cast ?? channel.cast {
                            (Text("Cast  ").foregroundStyle(Theme.faint) + Text(cast).foregroundStyle(Theme.dim)).font(.system(size: 14))
                        }
                        if let director = info?.director {
                            (Text("Director  ").foregroundStyle(Theme.faint) + Text(director).foregroundStyle(Theme.dim)).font(.system(size: 14))
                        }
                    }
                }
                if channel.kind == .series { episodeSection }
            }
            .padding(30)
            .padding(.top, info?.backdrop != nil ? 120 : 0)
        }
        // The title's wide artwork behind the top, fading into the page.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.cinemaBg
                if let backdrop = info?.backdrop {
                    Artwork(url: backdrop, name: channel.name)
                        .frame(height: 420)
                        .overlay(LinearGradient(colors: [.clear, Theme.cinemaBg], startPoint: .center, endPoint: .bottom))
                        .overlay(LinearGradient(colors: [Theme.cinemaBg.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing))
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .foregroundStyle(Theme.text).padding(18)
        }
        .task { await loadEpisodes() }
        .task { if let found = await model.details(for: channel) { withAnimation { info = found } } else { info = MediaInfo() } }
    }

    @ViewBuilder private var actions: some View {
        if channel.kind == .movie {
            if model.resumePosition(channel.id) != nil {
                Button { model.play(channel) } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(PillButtonStyle(primary: true))
                Button {
                    model.progress[channel.id] = nil
                    model.play(channel)
                } label: { Label("Start over", systemImage: "arrow.counterclockwise") }.buttonStyle(PillButtonStyle())
            } else {
                Button { model.play(channel) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(PillButtonStyle(primary: true))
            }
        } else if let next = upNext {
            Button { model.play(next, of: channel) } label: {
                Label("\(model.progress["\(channel.sourceId):ep:\(next.id)"] != nil ? "Resume" : "Play") S\(next.season) E\(next.episode)", systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(primary: true))
        }
    }

    /// The episode in progress, else the one after the last watched, else the first.
    private var upNext: Episode? {
        let watched = episodes.compactMap { e -> (Episode, WatchItem)? in
            model.progress["\(channel.sourceId):ep:\(e.id)"].map { (e, $0) }
        }
        guard let last = watched.max(by: { $0.1.updatedAt < $1.1.updatedAt }) else { return episodes.first }
        if !last.1.finished { return last.0 }
        guard let i = episodes.firstIndex(of: last.0), i + 1 < episodes.count else { return last.0 }
        return episodes[i + 1]
    }

    @ViewBuilder private var episodeSection: some View {
        if loadingEpisodes {
            ProgressView().tint(Theme.blue).frame(maxWidth: .infinity)
        } else if let error {
            Text(error).foregroundStyle(Theme.bad)
        } else if !episodes.isEmpty {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(seasons, id: \.self) { s in
                            Button("Season \(s)") { season = s }
                                .font(.system(size: 15, weight: .medium)).padding(.horizontal, 16).frame(height: 38)
                                .foregroundStyle(season == s ? Color.black : Theme.dim)
                                .background(season == s ? Theme.text : Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
            LazyVStack(spacing: 10) {
                ForEach(episodes.filter { $0.season == season }) { e in
                    EpisodeRow(episode: e, item: model.progress["\(channel.sourceId):ep:\(e.id)"]) { model.play(e, of: channel) }
                }
            }
        }
    }

    private func loadEpisodes() async {
        guard channel.kind == .series, episodes.isEmpty else { return }
        loadingEpisodes = true
        do {
            episodes = try await model.episodes(for: channel)
            season = upNext?.season ?? seasons.first ?? 1
        } catch {
            self.error = error.localizedDescription
        }
        loadingEpisodes = false
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let item: WatchItem?
    let play: () -> Void
    var body: some View {
        Button(action: play) {
            HStack(spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: episode.thumb, name: "E\(episode.episode) \(episode.title)").frame(width: 180, height: 101)
                    if let item, !item.finished {
                        Rectangle().fill(Theme.blue).frame(width: 180 * min(1, item.position / max(1, item.duration)), height: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(episode.episode). \(episode.title)").font(.system(size: 16, weight: .semibold))
                    if let plot = episode.plot { Text(plot).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(2) }
                    if let d = episode.duration { Text(d).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                }
                Spacer()
                if item?.finished == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.system(size: 22))
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.ello)
    }
}
