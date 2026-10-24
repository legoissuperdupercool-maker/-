import SwiftUI

// The Cinema look: a big billboard at the top, then rows of posters on a
// near-black page. Classic lives in HomeView / LibraryView.

struct CinemaHome: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @State private var detail: Channel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Billboard(items: billboardItems(model.movies + model.series)) { detail = $0 }
                if !model.continueWatching.isEmpty {
                    CinemaRow(title: "Continue watching for \(model.profile.name)") {
                        ForEach(model.continueWatching) { item in
                            ContinueCard(item: item) { model.resume(item) }
                        }
                    }
                }
                let topMovies = newest(model.movies, 10)
                if topMovies.count >= 5 {
                    CinemaRow(title: "Top 10 new movies") {
                        ForEach(Array(topMovies.enumerated()), id: \.element.id) { i, c in
                            Top10Card(channel: c, rank: i + 1) { detail = c }
                        }
                    }
                }
                if !model.myList.isEmpty {
                    CinemaRow(title: "My List", more: { tab = .mylist }) {
                        ForEach(model.myList) { c in CinemaPoster(channel: c) { detail = c } }
                    }
                }
                let recs = model.recommendations
                if !recs.forYou.isEmpty {
                    CinemaRow(title: "Picked for \(model.profile.name)") {
                        ForEach(recs.forYou) { c in CinemaPoster(channel: c) { detail = c } }
                    }
                }
                if let because = recs.because {
                    CinemaRow(title: "Because you watched \(because.title)") {
                        ForEach(because.items) { c in CinemaPoster(channel: c) { detail = c } }
                    }
                }
                let channels = model.favoriteChannels.isEmpty ? Array(model.live.prefix(16)) : model.favoriteChannels
                if !channels.isEmpty {
                    CinemaRow(title: model.favoriteChannels.isEmpty ? "Live TV" : "Your channels", more: { tab = .live }) {
                        ForEach(channels) { c in
                            ChannelCard(channel: c, favorite: model.isFavorite(c)) { model.play(c) }.contextMenu { ChannelMenu(channel: c) }
                        }
                    }
                }
                if !model.series.isEmpty {
                    CinemaRow(title: "New series", more: { tab = .series }) {
                        ForEach(newest(model.series, 24)) { c in CinemaPoster(channel: c) { detail = c } }
                    }
                }
                if !model.movies.isEmpty {
                    CinemaRow(title: "New movies", more: { tab = .movies }) {
                        ForEach(newest(model.movies, 24)) { c in CinemaPoster(channel: c) { detail = c } }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .sheet(item: $detail) { c in DetailView(channel: c) }
    }
}

/// Movies or Series: billboard, New, Top 10, then one row per category.
/// Picking a genre or searching switches to a poster grid.
struct CinemaLibrary: View {
    @Environment(AppModel.self) private var model
    let kind: StreamKind
    @State private var genre: String?
    @State private var query = ""
    @State private var detail: Channel?

    private var label: String { kind == .movie ? "Movies" : "Series" }
    private var all: [Channel] { kind == .movie ? model.movies : model.series }

    var body: some View {
        let sorted = newest(all, all.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if genre == nil && query.isEmpty {
                    Billboard(items: billboardItems(sorted)) { detail = $0 }
                        .overlay(alignment: .topLeading) { header.padding(.top, 108) }
                    CinemaRow(title: "New \(label.lowercased())") {
                        ForEach(sorted.prefix(30)) { c in CinemaPoster(channel: c) { detail = c } }
                    }
                    if sorted.count >= 10 {
                        CinemaRow(title: "Top 10 \(label.lowercased()) this week") {
                            ForEach(Array(sorted.prefix(10).enumerated()), id: \.element.id) { i, c in
                                Top10Card(channel: c, rank: i + 1) { detail = c }
                            }
                        }
                    }
                    ForEach(rows(sorted), id: \.id) { r in
                        CinemaRow(title: r.title, more: { genre = r.id }) {
                            ForEach(r.items) { c in CinemaPoster(channel: c) { detail = c } }
                        }
                    }
                } else {
                    header.padding(.top, 108)
                    let shown = sorted.filter { (genre == nil || $0.group == genre) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    Text("\(genre.flatMap { g in model.categories(kind).first { $0.id == g }?.name } ?? "Results") · \(shown.count)")
                        .font(.system(size: 15)).foregroundStyle(Theme.dim).padding(.horizontal, 28)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 16) {
                        ForEach(shown) { c in CinemaPoster(channel: c, width: nil) { detail = c } }
                    }
                    .padding(.horizontal, 28)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .sheet(item: $detail) { c in DetailView(channel: c) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(label).font(.system(size: 30, weight: .bold))
            Menu {
                Button("All genres") { genre = nil }
                ForEach(model.categories(kind)) { cat in Button(cleanCategory(cat.name)) { genre = cat.id } }
            } label: {
                HStack(spacing: 8) {
                    Text(genre.flatMap { g in model.categories(kind).first { $0.id == g }.map { cleanCategory($0.name) } } ?? "Genres").lineLimit(1)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 12).frame(height: 34)
                .background(.black.opacity(0.6))
                .overlay(Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            }
            .tint(.white)
            SearchField(text: $query, prompt: "Search \(label.lowercased())").frame(maxWidth: 300)
        }
        .padding(.horizontal, 28)
    }

    private func rows(_ sorted: [Channel]) -> [(id: String, title: String, items: [Channel])] {
        var groups: [String: [Channel]] = [:]
        for c in sorted { if let g = c.group { groups[g, default: []].append(c) } }
        return model.categories(kind)
            .compactMap { cat in groups[cat.id].map { (id: cat.id, title: cleanCategory(cat.name), items: Array($0.prefix(30)), n: $0.count) } }
            .sorted { $0.n > $1.n }
            .prefix(14)
            .map { (id: $0.id, title: $0.title, items: $0.items) }
    }
}

struct CinemaMyList: View {
    @Environment(AppModel.self) private var model
    @State private var detail: Channel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("My List").font(.system(size: 30, weight: .bold))
                if model.myList.isEmpty {
                    Text("Nothing here yet.").font(.system(size: 18)).padding(.top, 30)
                    Text("Use + on any movie or series to save it here.").foregroundStyle(Theme.dim)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 16) {
                        ForEach(model.myList) { c in CinemaPoster(channel: c, width: nil) { detail = c } }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
        }
        .sheet(item: $detail) { c in DetailView(channel: c) }
    }
}

// MARK: pieces

/// The big artwork at the top, rotating through a few titles.
struct Billboard: View {
    @Environment(AppModel.self) private var model
    let items: [Channel]
    let open: (Channel) -> Void
    @State private var index = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()

    var body: some View {
        let height: CGFloat = sizeClass == .compact ? 480 : 560
        ZStack(alignment: .bottomLeading) {
            if items.isEmpty {
                Theme.cinemaBg
            } else {
                let c = items[index % items.count]
                ZStack {
                    Artwork(url: c.logo, name: c.name).blur(radius: 40).opacity(0.55).scaleEffect(1.2)
                    if sizeClass != .compact {
                        HStack {
                            Spacer()
                            Artwork(url: c.logo, name: c.name)
                                .frame(width: 280, height: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                                .padding(.trailing, 60).padding(.top, 40)
                        }
                    }
                }
                .frame(height: height)
                .clipped()
                .id(c.id)
                .transition(.opacity)
                LinearGradient(colors: [Theme.cinemaBg.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
                LinearGradient(colors: [.clear, Theme.cinemaBg], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(c.kind == .movie ? "FILM" : "SERIES").font(.system(size: 11, weight: .heavy)).tracking(1.5)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.blue, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.onAccent)
                        Text("NEW ON ELLO").font(.system(size: 13, weight: .semibold)).tracking(1.5)
                    }
                    Text(c.cleanName).font(.system(size: sizeClass == .compact ? 34 : 50, weight: .heavy)).lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 10)
                    let meta = [c.year, c.genre, c.rating.map { String(format: "★ %.1f", $0) }].compactMap { $0 }
                    if !meta.isEmpty { Text(meta.joined(separator: "  ·  ")).foregroundStyle(Theme.text.opacity(0.85)) }
                    if let plot = c.plot, sizeClass != .compact {
                        Text(plot).lineLimit(3).foregroundStyle(Theme.text.opacity(0.85)).frame(maxWidth: 520, alignment: .leading)
                    }
                    HStack(spacing: 10) {
                        Button { c.kind == .movie ? model.play(c) : open(c) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(CinemaButtonStyle(primary: true))
                        Button { open(c) } label: { Label("More info", systemImage: "info.circle") }
                            .buttonStyle(CinemaButtonStyle())
                        Button { model.toggleMyList(c) } label: {
                            Image(systemName: model.inMyList(c) ? "checkmark" : "plus").font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44).overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                    if items.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(items.indices, id: \.self) { i in
                                Capsule().fill(i == index % items.count ? Theme.blue : .white.opacity(0.35))
                                    .frame(width: i == index % items.count ? 22 : 7, height: 7)
                                    .onTapGesture { withAnimation { index = i } }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
            }
        }
        .frame(height: height)
        .clipped()
        .onReceive(timer) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index += 1 }
        }
    }
}

struct CinemaButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 22).frame(height: 44)
            .foregroundStyle(primary ? Color.black : .white)
            .background(primary ? Color.white : Color(hex: 0x6D6D6E).opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A row title and a sideways scroller of cards.
struct CinemaRow<Content: View>: View {
    let title: String
    var more: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 20, weight: .bold))
                if let more {
                    Button(action: more) {
                        HStack(spacing: 2) {
                            Text("Explore all").font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Theme.blue)
                    }
                }
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) { content() }.padding(.horizontal, 28)
            }
        }
    }
}

/// Poster without a caption, like a streaming row.
struct CinemaPoster: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    var width: CGFloat? = 140
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Artwork(url: channel.logo, name: channel.name)
                .frame(width: width, height: width.map { $0 * 1.5 })
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomLeading) {
                    if model.resumePosition(channel.id) != nil {
                        Rectangle().fill(Theme.blue).frame(height: 3)
                    }
                }
        }
        .buttonStyle(ProfileTileStyle())
        .contextMenu {
            Button(model.inMyList(channel) ? "Remove from My List" : "Add to My List",
                   systemImage: model.inMyList(channel) ? "minus" : "plus") { model.toggleMyList(channel) }
        }
    }
}

/// Big outlined number next to a poster.
struct Top10Card: View {
    let channel: Channel
    let rank: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .bottom, spacing: -22) {
                Text("\(rank)")
                    .font(.system(size: 150, weight: .black))
                    .foregroundStyle(Theme.cinemaBg)
                    .shadow(color: .white.opacity(0.85), radius: 0, x: 1.5, y: 1.5)
                    .shadow(color: .white.opacity(0.85), radius: 0, x: -1.5, y: -1.5)
                    .frame(height: 160, alignment: .bottom)
                    .offset(y: 22)
                Artwork(url: channel.logo, name: channel.name)
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.leading, 6)
        }
        .buttonStyle(ProfileTileStyle())
    }
}

/// "Movies | Drama" → "Drama", "EN - Action" → "Action".
func cleanCategory(_ name: String) -> String {
    var s = name.replacingOccurrences(of: #"^\s*(movies?|films?|series|tv shows?|vod)\s*[|:\-–]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: #"^\s*\[?[A-Z]{2,3}\]?\s*[-|:•]\s*"#, with: "", options: .regularExpression)
    return s.isEmpty ? name : s
}

func newest(_ list: [Channel], _ n: Int) -> [Channel] {
    Array(list.sorted { ($0.added ?? 0) > ($1.added ?? 0) }.prefix(n))
}

/// Newest titles with artwork first, for the billboard.
func billboardItems(_ list: [Channel]) -> [Channel] {
    let fresh = newest(list, 30)
    let withArt = fresh.filter { $0.logo != nil }
    return Array((withArt.isEmpty ? fresh : withArt).prefix(5))
}
