import SwiftUI
import AVKit
import MobileVLCKit

/// Full-screen player. HLS / MP4 play in Apple's player (AirPlay, picture in
/// picture); MKV, TS, AVI and anything Apple's player can't open play in VLC,
/// automatically. Movies and episodes resume where you left off.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PlayRequest

    enum Engine { case apple, vlc }
    @State private var engine: Engine?
    @State private var failure: String?

    private static let vlcExtensions: Set<String> = ["mkv", "avi", "ts", "flv", "wmv", "mpg", "mpeg", "webm", "divx", "vob", "m2ts", "3gp"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = URL(string: request.url), !request.url.isEmpty, failure == nil {
                switch engine ?? Self.pick(url) {
                case .apple:
                    ApplePlayer(url: url, start: start) { pos, dur in
                        model.saveProgress(request, position: pos, duration: dur)
                    } onFailed: { _ in
                        engine = .vlc // Apple's player can't open it: try VLC.
                    }
                    .ignoresSafeArea()
                case .vlc:
                    VLCPlayerScreen(url: url, title: request.title, subtitle: request.subtitle, isLive: request.isLive, start: start) { pos, dur in
                        model.saveProgress(request, position: pos, duration: dur)
                    } onFailed: { message in
                        failure = message
                    } onClose: { dismiss() }
                }
            }
            if let failure = failure ?? (request.url.isEmpty ? "This is a demo title with no video." : nil) {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(Theme.bad)
                    Text("Couldn’t play this").font(.system(size: 22, weight: .semibold))
                    Text(failure).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 520)
                    Button("Back") { dismiss() }.buttonStyle(PillButtonStyle(primary: true))
                }
                .padding(30)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .overlay(alignment: .topLeading) {
            if (engine ?? URL(string: request.url).map(Self.pick)) != .vlc || failure != nil {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .foregroundStyle(.white).padding(20)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var start: Double? { request.isLive ? nil : model.resumePosition(request.key) }

    static func pick(_ url: URL) -> Engine {
        vlcExtensions.contains(url.pathExtension.lowercased()) ? .vlc : .apple
    }
}

// MARK: - Apple's player

private struct ApplePlayer: UIViewControllerRepresentable {
    let url: URL
    let start: Double?
    let onProgress: (Double, Double) -> Void
    let onFailed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProgress: onProgress, onFailed: onFailed) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]
        ]))
        let player = AVPlayer(playerItem: item)
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.attach(player, item: item, start: start)
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.save()
        vc.player?.pause()
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        let onProgress: (Double, Double) -> Void
        let onFailed: (String) -> Void
        private weak var player: AVPlayer?
        private var timeObserver: Any?
        private var statusObservation: NSKeyValueObservation?

        init(onProgress: @escaping (Double, Double) -> Void, onFailed: @escaping (String) -> Void) {
            self.onProgress = onProgress
            self.onFailed = onFailed
        }

        func attach(_ player: AVPlayer, item: AVPlayerItem, start: Double?) {
            self.player = player
            if let start, start > 0 {
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            // Save the position every 10 seconds.
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
                self?.save()
            }
            statusObservation = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let reason = item.error?.localizedDescription ?? "The stream couldn’t be opened."
                DispatchQueue.main.async { self?.onFailed(reason) }
            }
        }

        func save() {
            guard let player, let item = player.currentItem else { return }
            let pos = player.currentTime().seconds
            let dur = item.duration.seconds
            if pos.isFinite, dur.isFinite { onProgress(pos, dur) }
        }

        func detach() {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            statusObservation = nil
        }
    }
}

// MARK: - VLC

/// Wraps VLCMediaPlayer and publishes what the controls need (polled twice a second).
@MainActor
@Observable
final class VLCEngine {
    let player = VLCMediaPlayer()
    var playing = false
    var buffering = true
    var time: Double = 0
    var length: Double = 0
    var seekable = false
    struct Track: Hashable { let index: Int32; let name: String }
    var audioTracks: [Track] = []
    var subtitleTracks: [Track] = []
    var audioIndex: Int32 = -1
    var subtitleIndex: Int32 = -1
    var failed = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var everPlayed = false
    @ObservationIgnored private var openedAt = Date()

    func start(url: URL, at start: Double?, in view: UIView) {
        let media = VLCMedia(url: url)
        media.addOption(":http-user-agent=VLC/3.0.20 LibVLC/3.0.20")
        media.addOption(":network-caching=2000")
        if let start, start > 0 { media.addOption(":start-time=\(Int(start))") }
        player.drawable = view
        player.media = media
        player.play()
        openedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let state = player.state
        playing = player.isPlaying
        buffering = !playing && (state == .opening || state == .buffering || state == .esAdded)
        if playing { everPlayed = true }
        time = Double(player.time.intValue) / 1000
        if let len = player.media?.length.intValue, len > 0 { length = Double(len) / 1000 }
        seekable = player.isSeekable
        if state == .error || (!everPlayed && state == .stopped && Date().timeIntervalSince(openedAt) > 3)
            || (!everPlayed && Date().timeIntervalSince(openedAt) > 45) {
            failed = true
        }
        let names = player.audioTrackNames.compactMap { $0 as? String }
        let ids = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        if names.count == ids.count, names.count != audioTracks.count {
            audioTracks = zip(ids, names).map { Track(index: $0, name: $1) }
        }
        let subNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let subIds = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        if subNames.count == subIds.count, subNames.count != subtitleTracks.count {
            subtitleTracks = zip(subIds, subNames).map { Track(index: $0, name: $1) }
        }
        audioIndex = player.currentAudioTrackIndex
        subtitleIndex = player.currentVideoSubTitleIndex
    }

    func toggle() { if player.isPlaying { player.pause() } else { player.play() } }
    func skip(_ seconds: Int32) { if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) } }
    func seek(to fraction: Double) {
        player.position = Float(min(max(fraction, 0), 0.999))
        time = fraction * length
    }
    func setAudio(_ i: Int32) { player.currentAudioTrackIndex = i }
    func setSubtitle(_ i: Int32) { player.currentVideoSubTitleIndex = i }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.stop()
        player.drawable = nil
    }
}

private struct VLCSurface: UIViewRepresentable {
    let engine: VLCEngine
    let url: URL
    let start: Double?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        engine.start(url: url, at: start, in: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// VLC video with ello's own controls: tap to show, play/pause, ±10 s,
/// draggable seek bar, audio and subtitle tracks.
private struct VLCPlayerScreen: View {
    let url: URL
    let title: String
    let subtitle: String?
    let isLive: Bool
    let start: Double?
    let onProgress: (Double, Double) -> Void
    let onFailed: (String) -> Void
    let onClose: () -> Void

    @State private var engine = VLCEngine()
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragging: Double?
    @State private var lastSave = Date()

    var body: some View {
        ZStack {
            VLCSurface(engine: engine, url: url, start: start).ignoresSafeArea()
            Color.black.opacity(controls ? 0.35 : 0.001).ignoresSafeArea()
                .onTapGesture { if controls { controls = false } else { reveal() } }
            if engine.buffering {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controls { overlay.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: controls)
        .onAppear { reveal() }
        .onChange(of: engine.time) {
            if Date().timeIntervalSince(lastSave) > 10 { save() }
        }
        .onChange(of: engine.failed) {
            if engine.failed { onFailed("The stream couldn’t be opened. Check that your provider is online and your subscription is active.") }
        }
        .onDisappear {
            save()
            engine.stop()
        }
    }

    private func save() {
        lastSave = Date()
        if engine.length > 0, engine.time > 0 { onProgress(engine.time, engine.length) }
    }

    private func reveal() {
        controls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, engine.playing, dragging == nil { controls = false }
        }
    }

    private var overlay: some View {
        VStack {
            HStack(alignment: .top, spacing: 14) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                }
                Spacer()
                trackMenus
            }
            Spacer()
            HStack(spacing: 56) {
                if !isLive && engine.seekable {
                    roundButton("gobackward.10", size: 26) { engine.skip(-10); reveal() }
                }
                roundButton(engine.playing ? "pause.fill" : "play.fill", size: 34) { engine.toggle(); reveal() }
                if !isLive && engine.seekable {
                    roundButton("goforward.10", size: 26) { engine.skip(10); reveal() }
                }
            }
            Spacer()
            if isLive {
                HStack {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Theme.bad, in: Capsule())
                    Spacer()
                }
            } else if engine.length > 0 {
                seekBar
            }
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    private func roundButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).frame(width: size * 2.3, height: size * 2.3)
                .background(.black.opacity(0.45), in: Circle())
        }
    }

    private var seekBar: some View {
        let fraction = dragging ?? (engine.length > 0 ? engine.time / engine.length : 0)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 5)
                    Capsule().fill(Theme.blue).frame(width: max(0, geo.size.width * fraction), height: 5)
                    Circle().fill(.white).frame(width: dragging == nil ? 14 : 22)
                        .offset(x: geo.size.width * fraction - (dragging == nil ? 7 : 11))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = min(max(g.location.x / geo.size.width, 0), 1)
                        hideTask?.cancel()
                    }
                    .onEnded { g in
                        engine.seek(to: min(max(g.location.x / geo.size.width, 0), 1))
                        dragging = nil
                        reveal()
                    })
            }
            .frame(height: 30)
            HStack {
                Text(format(fraction * engine.length))
                Spacer()
                Text("-" + format(engine.length * (1 - fraction)))
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder private var trackMenus: some View {
        if engine.audioTracks.count > 2 {
            Menu {
                ForEach(engine.audioTracks.filter { $0.index >= 0 }, id: \.self) { t in
                    Button { engine.setAudio(t.index) } label: {
                        if t.index == engine.audioIndex { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
            } label: { trackIcon("speaker.wave.2.fill") }
        }
        if engine.subtitleTracks.count > 1 {
            Menu {
                ForEach(engine.subtitleTracks, id: \.self) { t in
                    Button { engine.setSubtitle(t.index) } label: {
                        if t.index == engine.subtitleIndex { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
            } label: { trackIcon("captions.bubble.fill") }
        }
    }

    private func trackIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 18)).frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle())
    }

    private func format(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
