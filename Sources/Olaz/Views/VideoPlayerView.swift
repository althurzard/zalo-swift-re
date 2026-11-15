import SwiftUI
import AVKit
import AVFoundation

/// One `AVPlayer` and everything the player UI shows about it. Volume and mute persist across videos and launches
/// (`OlazPrefs.videoVolume` / `videoMuted`).
@MainActor
@Observable
final class VideoPlayback {
    enum Status: Equatable { case loading, ready, failed }

    static let failureMessage = "Không thể phát video này."

    @ObservationIgnored let player: AVPlayer
    private(set) var status = Status.loading
    private(set) var isPlaying = false
    /// Played to the end: the play button turns into "replay" and starts over from 0.
    private(set) var ended = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// False for voice messages and other audio-only files.
    private(set) var hasVideo = true
    private(set) var volume: Double
    private(set) var isMuted: Bool
    private(set) var isScrubbing = false
    /// The glass bars are shown. They fade out after a moment without pointer movement while a video plays.
    private(set) var controlsVisible = true

    /// The bars stay up for audio (nothing else to look at) and for a video that is not playing.
    var barsVisible: Bool { controlsVisible || !hasVideo }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    /// The player was playing when a scrub began and goes back to playing once the seek that ends it has landed. It is
    /// cleared only then (or by an explicit play / pause), so a later seek that supersedes the exact one inherits it.
    @ObservationIgnored private var resumeAfterScrub = false
    /// Bumped by every seek: only the newest one finishes the job when it lands.
    @ObservationIgnored private var seekGeneration = 0
    /// A seek was issued and has not landed yet: `tick` must not move the knob back to the old position meanwhile.
    @ObservationIgnored private(set) var isSeeking = false
    /// Bars the pointer is over (they must stay up while it is).
    @ObservationIgnored private var hoveredControls: Set<String> = []
    /// The window showing this player (set by `VideoPlayerView`): the pointer is only hidden over it, and only while it is key.
    @ObservationIgnored weak var hostWindow: NSWindow?

    private static let idleDelay: Duration = .milliseconds(2500)

    init(url: URL, autoplay: Bool = true) {
        let defaults = UserDefaults.standard
        volume = (defaults.object(forKey: OlazPrefs.videoVolume) as? Double).map { min(max($0, 0), 1) } ?? 1
        isMuted = defaults.bool(forKey: OlazPrefs.videoMuted)
        let asset = Self.asset(for: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.volume = Float(volume)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
        observe()
        load(asset, autoplay: autoplay)
    }

    // MARK: Loading

    /// Periodic callbacks also fire when playback starts or stops, which is where `isPlaying` is derived; the end of the
    /// item has its own notification.
    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnd() }
            }
        }
    }

    private func load(_ asset: AVURLAsset, autoplay: Bool) {
        loadTask = Task { [weak self] in
            do {
                guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
                let length = try await asset.load(.duration).seconds
                let video = try await asset.loadTracks(withMediaType: .video)
                guard !Task.isCancelled, let self else { return }
                duration = length.isFinite && length > 0 ? length : 0
                hasVideo = !video.isEmpty
                status = .ready
                if !hasVideo { controlsVisible = true }
                if autoplay { play() }
            } catch {
                guard !Task.isCancelled, let self else { return }
                fail()
            }
        }
    }

    private func fail() {
        status = .failed
        isPlaying = false
        controlsVisible = true
        player.pause()
    }

    /// Pauses and releases the media (the window closed or the preview went away).
    func stop() {
        loadTask?.cancel()
        seekTask?.cancel()
        seekGeneration += 1
        isSeeking = false
        resumeAfterScrub = false
        isScrubbing = false
        hideTask?.cancel()
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }

    /// The periodic time observer and the end notification. Idempotent: `stop()` and `deinit` both call it.
    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// A playback dropped without `stop()` (a view torn down without `onDisappear`, a replaced preview) must not leave
    /// the player's observers and tasks behind. Observed state is not touched here.
    isolated deinit {
        loadTask?.cancel()
        seekTask?.cancel()
        hideTask?.cancel()
        removeObservers()
        player.pause()
    }

    // MARK: Transport

    private func tick(_ time: CMTime) {
        syncPlaying()
        if !isScrubbing, !isSeeking, !ended {
            let seconds = time.seconds
            if seconds.isFinite, abs(seconds - currentTime) > 0.01 { currentTime = max(0, seconds) }
        }
        if status == .ready, player.currentItem?.status == .failed { fail() }
    }

    private func syncPlaying() {
        let playing = player.rate != 0
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing { scheduleHide() } else { showControls() }
    }

    private func didEnd() {
        ended = true
        isPlaying = false
        if duration > 0 { currentTime = duration }
        showControls()
    }

    func play() {
        guard status == .ready else { return }
        resumeAfterScrub = false
        if ended {
            ended = false
            currentTime = 0
            startSeek(to: 0, exact: true)
        }
        player.play()
        syncPlaying()
    }

    func pause() {
        resumeAfterScrub = false
        player.pause()
        syncPlaying()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
        pointerMoved()
    }

    /// Jumps by `seconds` (arrow keys), exactly.
    func skip(by seconds: Double) {
        guard status == .ready else { return }
        seek(to: currentTime + seconds, exact: true)
        pointerMoved()
    }

    func seek(to time: Double, exact: Bool) {
        let target = clamped(time)
        currentTime = target
        ended = duration > 0 && target >= duration - 0.01
        startSeek(to: target, exact: exact)
    }

    private func clamped(_ time: Double) -> Double {
        duration > 0 ? min(max(time, 0), duration) : max(time, 0)
    }

    /// Only the newest seek counts: an older one that returns after it was superseded does nothing, so the newest always
    /// ends the "seeking" state (and resumes playback after a scrub), whatever the ordering.
    private func startSeek(to target: Double, exact: Bool) {
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        seekTask?.cancel()
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        seekTask = Task { [player] in
            _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
            guard generation == seekGeneration else { return }
            seekLanded()
        }
    }

    private func seekLanded() {
        isSeeking = false
        // Mid-drag the knob owns the position; the exact seek issued on release finishes the scrub.
        guard !isScrubbing else { return }
        if resumeAfterScrub {
            resumeAfterScrub = false
            if !ended { play() }
        }
        scheduleHide()
    }

    // MARK: Scrubbing

    /// The slider is being dragged: playback pauses (and resumes afterwards) so audio does not stutter behind the seeks.
    func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        // A resume still owed from an earlier scrub (its seek has not landed) stays owed.
        resumeAfterScrub = resumeAfterScrub || isPlaying
        if isPlaying { player.pause(); syncPlaying() }
        showControls()
    }

    func scrub(to time: Double) {
        beginScrub()
        seek(to: time, exact: false)
    }

    /// Released: the scrub is over at once (the label and slider follow the player again, the bars may hide); the exact
    /// seek lands later and brings playback back if it was running.
    func endScrub(at time: Double) {
        guard isScrubbing else { return }
        isScrubbing = false
        let target = clamped(time)
        currentTime = target
        ended = duration > 0 && target >= duration - 0.01
        startSeek(to: target, exact: true)
    }

    // MARK: Volume

    /// Level the slider shows (a muted player shows 0 but remembers `volume`).
    var displayedVolume: Double { isMuted ? 0 : volume }

    var volumeSymbol: String {
        switch displayedVolume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        if volume > 0 { isMuted = false }
        applyAudio()
    }

    /// ↑ / ↓: raising a muted player brings back its level first.
    func adjustVolume(by delta: Double) {
        if isMuted {
            guard delta > 0 else { return }
            isMuted = false
            if volume > 0 { applyAudio(); pointerMoved(); return }
        }
        setVolume(volume + delta)
        pointerMoved()
    }

    func toggleMute() {
        if volume == 0 {
            volume = 0.5
            isMuted = false
        } else {
            isMuted.toggle()
        }
        applyAudio()
        pointerMoved()
    }

    private func applyAudio() {
        player.volume = Float(volume)
        player.isMuted = isMuted
        let defaults = UserDefaults.standard
        defaults.set(volume, forKey: OlazPrefs.videoVolume)
        defaults.set(isMuted, forKey: OlazPrefs.videoMuted)
    }

    // MARK: Auto-hiding controls

    /// Any pointer movement (or key) over the player brings the bars back and restarts the idle timer.
    func pointerMoved() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    func setPointerOver(_ control: String, _ over: Bool) {
        if over {
            hoveredControls.insert(control)
            showControls()
        } else {
            hoveredControls.remove(control)
            scheduleHide()
        }
    }

    private func showControls() {
        hideTask?.cancel()
        hideTask = nil
        if !controlsVisible { controlsVisible = true }
    }

    private var mayHideControls: Bool { isPlaying && hasVideo && hoveredControls.isEmpty && !isScrubbing }

    /// Pointer events arrive at the display rate, so one timer loop serves them all: each event only moves the deadline.
    private func scheduleHide() {
        lastActivity = .now
        guard mayHideControls, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = lastActivity + Self.idleDelay - .now
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                    continue
                }
                hideTask = nil
                if mayHideControls { hideControls() }
                return
            }
        }
    }

    private func hideControls() {
        controlsVisible = false
        // The pointer goes away with the bars, but only when it is over this player's own window and that window is key
        // (the main window, or another app's, may be the one under it while a sheet or the viewer idles).
        if Self.mayHidePointer(in: hostWindow, mouse: NSEvent.mouseLocation) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    static func mayHidePointer(in window: NSWindow?, mouse: NSPoint) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        return window.frame.contains(mouse)
    }

    // MARK: Helpers

    /// "1:05", "12:34", "1:02:03".
    nonisolated static func timeString(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// AVFoundation picks the container by extension; an extension-less file (the official `ZaloDownloads` copy) is typed
    /// from its `ftyp` box instead.
    nonisolated static func asset(for url: URL) -> AVURLAsset {
        guard url.isFileURL, url.pathExtension.isEmpty, let mime = VideoPoster.mimeType(of: url) else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
    }

    /// Display size of the first video track (rotation applied), to size the viewer window before playing.
    nonisolated static func naturalSize(of file: URL) async -> CGSize? {
        let asset = Self.asset(for: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let result = CGSize(width: abs(rect.width), height: abs(rect.height))
        return result.width > 0 && result.height > 0 ? result : nil
    }
}

/// How the player's full-screen button reads and drives its window (the media viewer; the zCloud sheet has none).
struct FullScreenControl {
    let isOn: Bool
    let toggle: () -> Void
}

/// Reports the window its (invisible) view lives in, so the player knows whose pointer it may hide.
private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    final class Reader: NSView {
        var onChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { onChange?(window) }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.onChange = onChange }
}

/// AVKit's AppKit view without its own controls (the glass bar is ours). SwiftUI's `VideoPlayer` aborts in its
/// metadata initialisation when hosted from a SwiftPM-built bundle, hence the representable.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// Video / voice player: the picture, a click to play or pause, and a glass control bar (play, scrubber, time, volume,
/// optional full screen) that fades out while a video plays and the pointer rests.
struct VideoPlayerView: View {
    let playback: VideoPlayback
    var fullScreen: FullScreenControl?

    private var controlsShown: Bool { playback.barsVisible }

    var body: some View {
        ZStack {
            Color.black
            // Hidden once failed: AVKit draws its own "cannot play" glyph over the message.
            PlayerSurface(player: playback.player)
                .opacity(playback.hasVideo && playback.status != .failed ? 1 : 0)
            overlay
        }
        .background(WindowReader { playback.hostWindow = $0 })
        // Always on black, so always the dark glass (the zCloud sheet may be light).
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { playback.pointerMoved() }
        }
        .onDisappear { playback.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch playback.status {
        case .loading:
            ProgressView().controlSize(.large)
        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                Text(VideoPlayback.failureMessage).font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
        case .ready:
            if !playback.hasVideo {
                Image(systemName: "waveform")
                    .font(.system(size: 84, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { playback.togglePlay() }
                .accessibilityHidden(true)
            controlBar
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(controlsShown ? 1 : 0)
                .allowsHitTesting(controlsShown)
                .animation(.easeOut(duration: 0.2), value: controlsShown)
        }
    }

    // MARK: Control bar

    private var controlBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ViewerIconButton(symbol: playSymbol, label: playLabel, help: playLabel + (playback.ended ? "" : " (Dấu cách)")) { playback.togglePlay() }
                scrubber
                volumeControl
                if let fullScreen {
                    ViewerIconButton(symbol: fullScreen.isOn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                     label: fullScreen.isOn ? "Thoát toàn màn hình" : "Toàn màn hình",
                                     help: (fullScreen.isOn ? "Thoát toàn màn hình" : "Toàn màn hình") + " (F)") { fullScreen.toggle() }
                }
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .onHover { playback.setPointerOver("bar", $0) }
    }

    private var playSymbol: String {
        playback.ended ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill"
    }

    private var playLabel: String {
        playback.ended ? "Phát lại" : playback.isPlaying ? "Tạm dừng" : "Phát"
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(VideoPlayback.timeString(playback.currentTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { value in
                        if playback.isScrubbing { playback.scrub(to: value) } else { playback.seek(to: value, exact: true) }
                    }),
                in: 0...max(playback.duration, 0.1),
                onEditingChanged: { editing in
                    if editing { playback.beginScrub() } else { playback.endScrub(at: playback.currentTime) }
                }
            )
            .controlSize(.small)
            .disabled(playback.duration <= 0)
            .accessibilityLabel("Vị trí phát")
            .accessibilityValue("\(VideoPlayback.timeString(playback.currentTime)) trên \(VideoPlayback.timeString(playback.duration))")
            Text(VideoPlayback.timeString(playback.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule())
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button { playback.toggleMute() } label: {
                Image(systemName: playback.volumeSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help((playback.displayedVolume == 0 ? "Bật tiếng" : "Tắt tiếng") + " (M)")
            .accessibilityLabel(playback.displayedVolume == 0 ? "Bật tiếng" : "Tắt tiếng")
            Slider(value: Binding(get: { playback.displayedVolume }, set: { playback.setVolume($0) }), in: 0...1)
                .controlSize(.small)
                .frame(width: 90)
                .help("Âm lượng (↑ ↓)")
                .accessibilityLabel("Âm lượng")
                .accessibilityValue("\(Int((playback.displayedVolume * 100).rounded())) phần trăm")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule())
    }
}
