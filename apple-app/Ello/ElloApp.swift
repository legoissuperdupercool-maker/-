import SwiftUI
import AVFoundation

@main
struct ElloApp: App {
    @State private var model = AppModel()

    init() {
        // Keep playing with the silent switch on, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { await model.load() }
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case home = "Home", live = "Live TV", guide = "Guide", movies = "Movies", series = "Series", mylist = "My List"
    var id: String { rawValue }
    static let classic: [Tab] = [.home, .live, .guide, .movies, .series]
    static let cinema: [Tab] = [.home, .series, .movies, .live, .guide, .mylist]
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = RootView.startTab
    @State private var showSettings = RootView.startScreen == "settings"

    /// Screenshot runs pick the first screen with `-tab movies` etc.
    static var startTab: Tab {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let t = Tab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(args[i + 1]) }) {
            return t
        }
        return .home
    }
    static var startScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
        @Bindable var model = model
        let cinema = model.uiTheme == .cinema
        ZStack(alignment: .top) {
            if cinema {
                Theme.cinemaBg.ignoresSafeArea()
            } else {
                AppBackground(profile: model.profile)
            }
            VStack(spacing: 0) {
                if !cinema || !fullBleed { TopBar(tab: $tab, showSettings: $showSettings) }
                if model.sources.isEmpty {
                    WelcomeView(showSettings: $showSettings)
                } else if model.loading {
                    LoadingView(text: model.status ?? "Loading…")
                } else if let error = model.error, model.live.isEmpty, model.movies.isEmpty {
                    ErrorView(text: error)
                } else if cinema {
                    switch tab {
                    case .home: CinemaHome(tab: $tab)
                    case .live: LiveView()
                    case .guide: GuideView()
                    case .movies: CinemaLibrary(kind: .movie).id("movies")
                    case .series: CinemaLibrary(kind: .series).id("series")
                    case .mylist: CinemaMyList()
                    }
                } else {
                    switch tab {
                    case .home: HomeView(tab: $tab)
                    case .live: LiveView()
                    case .guide: GuideView()
                    case .movies: LibraryView(kind: .movie)
                    case .series: LibraryView(kind: .series)
                    case .mylist: HomeView(tab: $tab)
                    }
                }
            }
            // Cinema pages with a billboard run under a see-through top bar.
            if cinema && fullBleed {
                TopBar(tab: $tab, showSettings: $showSettings)
                    .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
        }
        .id(model.accentVersion)
        .overlay {
            if model.showProfilePicker { ProfilePickerView().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.showProfilePicker)
        .onChange(of: model.uiTheme) { if model.uiTheme == .classic && tab == .mylist { tab = .home } }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(item: $model.playing) { req in PlayerView(request: req) }
    }

    /// Billboard pages: Home, Movies and Series once the catalogue is in.
    private var fullBleed: Bool {
        [.home, .movies, .series].contains(tab) && !model.sources.isEmpty && !model.loading
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @Binding var showSettings: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    private var cinema: Bool { model.uiTheme == .cinema }

    var body: some View {
        HStack(spacing: cinema ? 2 : 6) {
            if !compact {
                Wordmark(size: 22).padding(.trailing, 18)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cinema ? 2 : 6) {
                    ForEach(cinema ? Tab.cinema : Tab.classic) { t in
                        if cinema {
                            Button { tab = t } label: {
                                VStack(spacing: 4) {
                                    Text(t.rawValue).font(.system(size: 16, weight: tab == t ? .bold : .medium))
                                        .foregroundStyle(tab == t ? Color.white : Color.white.opacity(0.72))
                                    Capsule().fill(tab == t ? Theme.blue : .clear).frame(width: 22, height: 3)
                                }
                                .padding(.horizontal, compact ? 8 : 12).frame(height: 44)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(t.rawValue) { tab = t }
                                .font(.system(size: 16, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, compact ? 10 : 16)
                                .frame(height: 38)
                                .foregroundStyle(tab == t ? Color.black : Theme.dim)
                                .background(tab == t ? Theme.text : Color.clear, in: Capsule())
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            Spacer(minLength: 8)
            if model.sources.count > 1 {
                Menu {
                    ForEach(model.sources) { s in
                        Button(s.name) { model.select(s.id) }
                    }
                } label: {
                    if compact {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 17))
                    } else {
                        Label(model.currentSource?.name ?? "Source", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .tint(Theme.text)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .foregroundStyle(cinema ? .white : Theme.dim)
            Button { model.showProfilePicker = true } label: { Avatar(profile: model.profile, size: 36) }
                .padding(.leading, 4)
        }
        .padding(.horizontal, compact ? 14 : 28)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct WelcomeView: View {
    @Binding var showSettings: Bool
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("Logo").resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22))
            Text("Welcome to ello smartTV").font(.system(size: 32, weight: .semibold))
            Text("Add your IPTV provider to get started: an Xtream Codes login or an M3U playlist.")
                .font(.system(size: 17)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Add a source") { showSettings = true }.buttonStyle(PillButtonStyle(primary: true)).padding(.top, 8)
            Spacer()
        }
        .padding()
    }
}

struct LoadingView: View {
    let text: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large).tint(Theme.blue)
            Text(text).foregroundStyle(Theme.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ErrorView: View {
    @Environment(AppModel.self) private var model
    let text: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.bad)
            Text("Couldn’t load your source").font(.system(size: 22, weight: .semibold))
            Text(text).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Try again") { Task { await model.load(force: true) } }.buttonStyle(PillButtonStyle(primary: true))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
