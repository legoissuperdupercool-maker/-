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
    @AppStorage("intro") private var introOn = true
    @Environment(\.horizontalSizeClass) private var rootSizeClass
    @State private var introDone = false

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
        let cinema = model.uiTheme.isCinema
        // Theater on iPad: a side menu instead of the top bar.
        let rail = model.uiTheme == .theater && rootSizeClass != .compact
        ZStack(alignment: .top) {
            if cinema {
                LookBackground().ignoresSafeArea()
            } else {
                AppBackground(profile: model.profile)
            }
            VStack(spacing: 0) {
                if !rail && (!cinema || !fullBleed) { TopBar(tab: $tab, showSettings: $showSettings) }
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
            // Theater on iPad: room for the side menu along the left edge.
            .padding(.leading, rail ? SideRail.width : 0)
            // Cinema pages with a billboard run under a see-through top bar.
            if cinema && fullBleed && !rail {
                TopBar(tab: $tab, showSettings: $showSettings)
                    .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
        }
        // The side menu, fixed to the left edge of the screen for the full height.
        .overlay(alignment: .leading) {
            if rail {
                #if os(tvOS)
                // TVs cut off the edges: the menu stays in the safe area (its backdrop runs to the edge).
                SideRail(tab: $tab, showSettings: $showSettings)
                #else
                SideRail(tab: $tab, showSettings: $showSettings).ignoresSafeArea()
                #endif
            }
        }
        .id(model.accentVersion)
        .overlay {
            if model.showProfilePicker { ProfilePickerView().transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            // Movies and series still loading in the background.
            if !model.loading, let status = model.status {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(status).font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 16).frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.opacity)
            }
        }
        .overlay {
            if introOn && !introDone && !model.demo { LogoIntro { introDone = true } }
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

/// A menu entry: which page, its name in the look and its icon (the Windows app's menus).
struct NavItem: Identifiable {
    let tab: Tab
    let label: String
    let icon: String
    var id: String { tab.rawValue }

    static func items(_ look: UITheme) -> [NavItem] {
        switch look {
        case .premium:
            return [.init(tab: .home, label: "Home", icon: "house.fill"), .init(tab: .movies, label: "Movies", icon: "film.fill"),
                    .init(tab: .series, label: "TV Shows", icon: "rectangle.stack.fill"), .init(tab: .live, label: "Live TV", icon: "tv.fill"),
                    .init(tab: .guide, label: "Guide", icon: "calendar"), .init(tab: .mylist, label: "My Stuff", icon: "bookmark.fill")]
        case .wonder:
            return [.init(tab: .home, label: "Home", icon: "house.fill"), .init(tab: .mylist, label: "Watchlist", icon: "plus"),
                    .init(tab: .movies, label: "Movies", icon: "film.fill"), .init(tab: .series, label: "Series", icon: "rectangle.stack.fill"),
                    .init(tab: .live, label: "Live", icon: "tv.fill")]
        case .glass:
            return [.init(tab: .home, label: "Watch Now", icon: "play.fill"), .init(tab: .movies, label: "Movies", icon: "film.fill"),
                    .init(tab: .series, label: "TV Shows", icon: "rectangle.stack.fill"), .init(tab: .live, label: "Live", icon: "tv.fill"),
                    .init(tab: .guide, label: "Guide", icon: "calendar"), .init(tab: .mylist, label: "Library", icon: "bookmark.fill")]
        case .theater:
            return [.init(tab: .home, label: "Home", icon: "house.fill"), .init(tab: .series, label: "Series", icon: "rectangle.stack.fill"),
                    .init(tab: .movies, label: "Movies", icon: "film.fill"), .init(tab: .live, label: "Live TV", icon: "tv.fill"),
                    .init(tab: .guide, label: "TV Guide", icon: "calendar"), .init(tab: .mylist, label: "My List", icon: "bookmark.fill")]
        case .classic:
            return Tab.classic.map { .init(tab: $0, label: $0.rawValue, icon: "circle") }
        }
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @Binding var showSettings: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    private var cinema: Bool { model.uiTheme.isCinema }
    private var look: UITheme { model.uiTheme }

    var body: some View {
        HStack(spacing: cinema ? 2 : 6) {
            if !compact {
                Wordmark(size: 22 * UI.s).padding(.trailing, 18)
            }
            if look == .glass && !compact {
                // Glass: the tab bar floats in the middle.
                Spacer(minLength: 8)
                tabs
                Spacer(minLength: 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { tabs }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                Spacer(minLength: 8)
            }
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

    private var tabs: some View {
        HStack(spacing: cinema ? 2 : 6) {
            if cinema {
                ForEach(NavItem.items(look)) { item in
                    Button { tab = item.tab } label: { CinemaTab(item: item, on: tab == item.tab, look: look, compact: compact) }
                        .buttonStyle(.ello)
                }
            } else {
                ForEach(Tab.classic) { t in
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
        .padding(look == .glass ? 4 : 0)
        .background {
            if look == .glass { Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(.white.opacity(0.15))) }
        }
    }
}

/// Theater: the side menu of icons, like the Windows app's. On Apple TV it is bigger and
/// opens out with the names while you're in it (as Netflix does there).
struct SideRail: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @Binding var showSettings: Bool
    @FocusState private var focus: String?

    #if os(tvOS)
    static let width: CGFloat = 130
    private let icon: CGFloat = 34
    private let row: CGFloat = 84
    #else
    static let width: CGFloat = 72
    private let icon: CGFloat = 21
    private let row: CGFloat = 52
    #endif

    private var open: Bool {
        #if os(tvOS)
        return focus != nil
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.showProfilePicker = true } label: {
                HStack(spacing: 18) {
                    Avatar(profile: model.profile, size: icon + 18)
                    if open { Text(model.profile.name).font(.system(size: icon * 0.75, weight: .semibold)) }
                }
                .frame(minWidth: Self.width, alignment: open ? .leading : .center)
                .padding(.leading, open ? 26 : 0)
            }
            .buttonStyle(.elloPlain)
            .focused($focus, equals: "profile")
            .padding(.top, 18).padding(.bottom, 26)
            ForEach(NavItem.items(.theater)) { item in
                Button { tab = item.tab } label: { entry(item.icon, item.label, on: tab == item.tab, key: item.id) }
                    .buttonStyle(.elloPlain)
                    .focused($focus, equals: item.id)
                    .accessibilityLabel(item.label)
            }
            Spacer()
            if model.sources.count > 1 {
                Menu {
                    ForEach(model.sources) { s in Button(s.name) { model.select(s.id) } }
                } label: {
                    entry("antenna.radiowaves.left.and.right", model.currentSource?.name ?? "Source", on: false, key: "source")
                }
                .focused($focus, equals: "source")
            }
            Button { showSettings = true } label: { entry("gearshape.fill", "Settings", on: false, key: "settings") }
                .buttonStyle(.elloPlain)
                .focused($focus, equals: "settings")
                .padding(.bottom, 14)
        }
        .padding(.vertical, 20)
        .frame(width: open ? 360 : Self.width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background {
            LinearGradient(colors: open ? [.black, .black.opacity(0.92), .black.opacity(0.0)] : [.black, .black.opacity(0.88)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: open ? 560 : Self.width)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ignoresSafeArea()
        }
        .animation(.easeOut(duration: 0.2), value: open)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func entry(_ symbol: String, _ label: String, on: Bool, key: String) -> some View {
        let lit = on || focus == key
        return HStack(spacing: 22) {
            Image(systemName: symbol)
                .font(.system(size: icon, weight: .semibold))
                .frame(width: Self.width - (open ? 52 : 0))
            if open {
                Text(label).font(.system(size: icon * 0.8, weight: on ? .bold : .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(lit ? Color.white : Color.white.opacity(0.55))
        .frame(height: row)
        .frame(minWidth: Self.width, alignment: .leading)
        .overlay(alignment: .leading) {
            if on { Capsule().fill(Theme.blue).frame(width: 4, height: row * 0.46) }
        }
        .background {
            if focus == key { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12)).padding(.horizontal, 10) }
        }
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
            ProgressView().bigSpinner().tint(Theme.blue)
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

/// A tab in the cinema top bar, drawn per look.
struct CinemaTab: View {
    let item: NavItem
    let on: Bool
    let look: UITheme
    let compact: Bool

    var body: some View {
        switch look {
        case .glass:
            Text(item.label)
                .font(.system(size: 15 * UI.s, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, compact ? 12 : 16).frame(height: 36)
                .background(on ? Color.white : Color.clear, in: Capsule())
        case .wonder:
            VStack(spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: item.icon).font(.system(size: 14 * UI.s, weight: .bold))
                    Text(item.label.uppercased()).font(.system(size: 14 * UI.s, weight: .bold)).tracking(1.6)
                }
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.75))
                Capsule().fill(on ? Color.white : .clear).frame(height: 2)
            }
            .fixedSize()
            .padding(.horizontal, compact ? 8 : 12).frame(height: 44)
        case .premium:
            VStack(spacing: 4) {
                Text(item.label).font(.system(size: 16 * UI.s, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.7))
                Capsule().fill(on ? Color.white : .clear).frame(height: 2)
            }
            .fixedSize()
            .padding(.horizontal, compact ? 8 : 12).frame(height: 44)
        default:
            VStack(spacing: 4) {
                Text(item.label).font(.system(size: 16 * UI.s, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.72))
                Capsule().fill(on ? Theme.blue : .clear).frame(width: 22, height: 3)
            }
            .padding(.horizontal, compact ? 8 : 12).frame(height: 44)
        }
    }
}
