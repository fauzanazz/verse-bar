import AppKit
import AVFoundation
import Combine
import MediaPlayer

/// Plays the offline library **and** remote streams through `AVPlayer` (one
/// code path for both) and feeds the result into `PlaybackEngine` so every
/// existing consumer (menu bar, lyrics, Music Island, Discord, listening
/// stats) follows local playback with zero changes to them.
///
/// `isEngaged` (we own playback) is the source-of-truth flag that makes
/// `PlaybackEngine.poll()` stand down; when playback stops, the external poll
/// cascade takes over again.
final class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    private struct PlaybackSnapshot: Codable {
        var queue: PlayQueue
        var elapsed: TimeInterval
    }

    private static let stateURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.playerstudio.PlayerStudio", isDirectory: true)
        .appendingPathComponent("PlaybackState.json")

    /// Position the restored track resumes from; consumed by the first
    /// `startCurrent()` after launch and cleared by every real `load()`.
    private var pendingResume: TimeInterval = 0

    @Published private(set) var queue = PlayQueue()
    @Published private(set) var isPlaying = false
    @Published private(set) var isKaraoke = false
    @Published var volume: Double {
        didSet {
            player?.volume = Float(volume)
            AppSettings.shared.playerVolume = volume
        }
    }

    private var player: AVPlayer?
    private var timer: Timer?
    private var consecutiveFailures = 0
    private var artworkDataCache: [String: Data] = [:]
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var retriedTrackIDs: Set<String> = []
    /// The item whose failure triggered an in-flight stream refresh, so the
    /// duplicate report (status → .failed + end-time notification) of that one
    /// failure is not mistaken for a second failure.
    private var refreshInFlightForItem: AVPlayerItem?

    var isEngaged: Bool { player != nil }

    /// The local player owns the transport: it is live, or it holds a restored
    /// queue and no external source has taken over. `isEngaged` stays narrow —
    /// widening it would kill browser polling forever after a restore.
    var ownsTransport: Bool {
        player != nil || (queue.current != nil && !PlaybackEngine.shared.isSourceActive)
    }

    /// ponytail: saved at track change / play-pause / stop / quit, not on every
    /// tick — a crash mid-song loses the position, nothing else.
    private func save() {
        // XCTest processes share the developer's Application Support path;
        // fixtures must never replace the real app's saved queue.
        guard NSClassFromString("XCTestCase") == nil else { return }
        try? FileManager.default.createDirectory(
            at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard queue.current != nil else { try? FileManager.default.removeItem(at: Self.stateURL); return }
        guard let data = try? JSONEncoder().encode(PlaybackSnapshot(queue: queue, elapsed: elapsed))
        else { return }
        try? data.write(to: Self.stateURL)
    }

    /// Flush the exact quit-time position; called from `applicationWillTerminate`.
    func saveState() { save() }

    var elapsed: TimeInterval {
        guard let t = player?.currentTime().seconds, t.isFinite else { return pendingResume }
        return t
    }

    /// Which file backs playback: the karaoke sidecar when enabled and present,
    /// else the original. The fallback is defensive only — `startCurrent` clears
    /// `isKaraoke` for a track with no sidecar before we get here.
    private static func audioURL(for track: LibraryTrack, karaoke: Bool) -> URL {
        guard karaoke else { return track.url }
        let instrumental = VocalSeparationService.instrumentalURL(for: track)
        return FileManager.default.fileExists(atPath: instrumental.path) ? instrumental : track.url
    }


    private override init() {
        volume = AppSettings.shared.playerVolume
        super.init()
        setupRemoteCommands()

        // Skip under xctest so the suite never inherits a stale queue from the
        // developer's real state file (same guard triggerNotification uses).
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard let data = try? Data(contentsOf: Self.stateURL),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
              let track = snapshot.queue.current else { return }
        queue = snapshot.queue
        pendingResume = snapshot.elapsed
        // Deferred: PlaybackEngine.shared may still be initializing this singleton's peers.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            PlaybackEngine.shared.publishRestoredTrack(
                title: track.title, artist: track.artist, duration: track.duration,
                elapsed: snapshot.elapsed, artworkData: self.artworkData(for: track), fileID: track.id
            )
        }
    }

    // MARK: - Playback control

    func play(_ tracks: [LibraryTrack], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue.load(tracks, startAt: index)
        consecutiveFailures = 0
        startCurrent()
    }

    func togglePlayPause() {
        // `stop()` tears the player down but keeps the queue: press play = restart the current track.
        guard let player else { startCurrent(resumeAt: pendingResume); return }
        if player.timeControlStatus == .paused {
            player.play()
            isPlaying = true
            startTimer()
        } else {
            player.pause()
            isPlaying = false
        }
        publishTrack()
        save()
    }

    func next() {
        if queue.advance() == nil { stop(); return }
        startCurrent()
    }

    /// Restarts the current track when more than 3 s in, else goes back.
    func previous() {
        if let player, elapsed > 3 {
            player.seek(to: .zero)
            publishTrack()
            return
        }
        _ = queue.rewind()
        startCurrent()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let itemSeconds = player.currentItem?.duration.seconds ?? .nan
        let maxSeconds = (itemSeconds.isFinite && itemSeconds > 0)
            ? itemSeconds
            : (queue.current?.duration ?? seconds)
        let target = min(max(0, seconds), maxSeconds)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            self?.publishTrack()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        teardownItemObservers()
        player?.pause()
        player = nil
        isPlaying = false
        retriedTrackIDs.removeAll()
        refreshInFlightForItem = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        // Release the poll short-circuit so external playback tracking resumes.
        PlaybackEngine.shared.clearLocalTrack()
        save()
    }

    func setShuffled(_ on: Bool) {
        queue.setShuffled(on)
    }

    func cycleRepeatMode() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
    }

    func playNext(_ track: LibraryTrack) {
        queue.insertNext(track)
    }

    func addToQueue(_ track: LibraryTrack) {
        queue.append(track)
    }

    // MARK: - Karaoke

    /// Rebuilds the player against the currently resolved source, keeping
    /// position and play/pause state. Used when karaoke is toggled mid-track.
    /// AVPlayer clamps over-duration seeks itself, so no manual clamp needed.
    private func reloadPreservingPosition() {
        guard let track = queue.current else { return }
        let resumeAt = elapsed
        // `isPlaying` is user intent; `timeControlStatus` lags while buffering.
        let wasPlaying = isPlaying
        load(url: Self.audioURL(for: track, karaoke: isKaraoke), resumeAt: resumeAt)
        if !wasPlaying {
            player?.pause()
            isPlaying = false
            publishTrack()
        }
    }

    /// Toggle target for the transport bar. `isKaraoke` flips only when the
    /// instrumental actually backs playback; a press with no sidecar yet starts
    /// separation and `enableKaraoke(for:)` flips it when the file lands.
    /// Refusals and progress are reported through `VocalSeparationService.state`.
    func setKaraoke(_ on: Bool) {
        guard isKaraoke != on else { return }
        guard let track = queue.current else { return }
        if on, !VocalSeparationService.hasInstrumental(for: track) {
            VocalSeparationService.shared.separate(track, autoEnable: true)
            return
        }
        isKaraoke = on
        reloadPreservingPosition()
    }

    /// Called by VocalSeparationService when a requested instrumental is ready.
    /// Ignored when the user has already moved to another track.
    func enableKaraoke(for track: LibraryTrack) {
        guard queue.current?.id == track.id else { return }
        isKaraoke = true
        reloadPreservingPosition()
    }

    // MARK: - Internals

    private func startCurrent(resumeAt: TimeInterval = 0) {
        guard let track = queue.current else { stop(); return }
        // A karaoke session carries only to tracks that actually have an
        // instrumental — otherwise the flag would advertise karaoke while the
        // original file plays.
        if isKaraoke, !VocalSeparationService.hasInstrumental(for: track) { isKaraoke = false }
        load(url: Self.audioURL(for: track, karaoke: isKaraoke), resumeAt: resumeAt)
        Logger.info("▶️ Playing \(track.artist) — \(track.title)", category: "playback")
        save()
    }

    /// Fresh AVPlayerItem + observers, then play. `resumeAt > 0` is the
    /// stream-refresh path (expired URL replaced mid-song).
    private func load(url: URL, resumeAt: TimeInterval) {
        pendingResume = 0
        teardownItemObservers()
        let item = AVPlayerItem(url: url)
        let active = player ?? AVPlayer()
        active.replaceCurrentItem(with: item)
        active.volume = Float(volume)
        player = active
        observeItem(item)
        if resumeAt > 0 {
            active.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        active.play()
        isPlaying = true
        startTimer()
        publishTrack()
    }

    private func observeItem(_ item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            self?.handleDidPlayToEnd(item)
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            self?.handleItemFailure(item)
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleItemStatus(item)
            }
        }
    }

    private func teardownItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        statusObservation?.invalidate()
        endObserver = nil
        failObserver = nil
        statusObservation = nil
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard player?.currentItem === item else { return }  // stale item, replaced
        switch item.status {
        case .readyToPlay:
            consecutiveFailures = 0
            retriedTrackIDs.removeAll()   // each fresh failure earns one retry
            let seconds = item.duration.seconds
            if seconds.isFinite, seconds > 0, let id = queue.current?.id,
               (queue.current?.duration ?? 0) <= 0 {
                queue.setDuration(seconds, forTrackID: id)
            }
            publishTrack()
        case .failed:
            handleItemFailure(item)
        default:
            break
        }
    }

    private func handleDidPlayToEnd(_ item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        if queue.repeatMode == .one {
            player?.seek(to: .zero)
            player?.play()
            isPlaying = true
            startTimer()
            publishTrack()
            return
        }
        if queue.advance() == nil { stop(); return }
        startCurrent()
    }

    /// AVPlayer reports failures asynchronously; the old skip-ahead logic lives
    /// here now, plus the one-shot stream expiry repair.
    private func handleItemFailure(_ failedItem: AVPlayerItem) {
        guard let track = queue.current, player?.currentItem === failedItem else { return }
        // Karaoke swap: a bad sidecar degrades to the original instead of
        // taking the skip-ahead path — never silence for a broken instrumental.
        if isKaraoke, VocalSeparationService.hasInstrumental(for: track) {
            Logger.error("Karaoke sidecar failed, reverting to original",
                         category: "playback", error: player?.currentItem?.error)
            isKaraoke = false
            load(url: track.url, resumeAt: elapsed)
            return
        }
        Logger.error("Playback failed for \(track.url.absoluteString)",
                     category: "playback", error: player?.currentItem?.error)
        // Stream URLs expire (~6 h) and can 403 mid-song: re-resolve once and
        // resume in place. Second failure falls through to the skip path.
        if track.youtubeID != nil, !retriedTrackIDs.contains(track.id) {
            retriedTrackIDs.insert(track.id)
            refreshInFlightForItem = failedItem
            let resumeAt = elapsed
            YouTubeStreamService.shared.refreshStream(for: track) { [weak self] url in
                guard let self else { return }
                self.refreshInFlightForItem = nil
                // Playback moved on (stop / next / new queue) — do not restart it.
                guard self.player != nil, self.queue.current?.id == track.id else { return }
                guard let url else {
                    self.skipFailedTrack()
                    return
                }
                self.load(url: url, resumeAt: resumeAt)
            }
            return
        }
        // One failure can arrive twice (status → .failed and the end-time
        // notification); the refresh above already owns this item.
        if failedItem === refreshInFlightForItem { return }
        skipFailedTrack()
    }

    /// Old corrupt-file behavior, unchanged: skip ahead, and never spin forever.
    private func skipFailedTrack() {
        consecutiveFailures += 1
        if consecutiveFailures >= queue.tracks.count { stop() } else { next() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let player, player.timeControlStatus == .playing else { return }
        publishTrack()
    }

    private var currentDuration: TimeInterval {
        let itemSeconds = player?.currentItem?.duration.seconds ?? .nan
        return (itemSeconds.isFinite && itemSeconds > 0) ? itemSeconds : (queue.current?.duration ?? 0)
    }

    /// Pushes current state into PlaybackEngine (the single input every
    /// consumer reads) and keeps MPNowPlayingInfoCenter fresh for media keys.
    private func publishTrack() {
        guard let track = queue.current, let player else { return }
        PlaybackEngine.shared.publishLocalTrack(
            title: track.title,
            artist: track.artist,
            duration: currentDuration,
            elapsed: elapsed,
            isPaused: player.timeControlStatus == .paused,
            artworkData: artworkData(for: track),
            fileID: track.id
        )
        updateNowPlayingInfo()
    }

    /// Stream artwork arrives after playback starts; drop the memoized Data and
    /// republish so the menu bar, island, and Now Playing pick it up.
    func refreshArtwork(for trackID: String) {
        guard queue.current?.id == trackID else { return }
        artworkDataCache.removeValue(forKey: trackID)
        publishTrack()
    }

    private func artworkData(for track: LibraryTrack) -> Data? {
        if let cached = artworkDataCache[track.id] { return cached }
        guard let data = LibraryService.shared.artwork(for: track)?.tiffRepresentation else { return nil }
        artworkDataCache[track.id] = data
        return data
    }

    private func updateNowPlayingInfo() {
        guard let track = queue.current, let player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: currentDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .paused ? 0.0 : 1.0,
        ]
        if let data = artworkData(for: track), let image = NSImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// Keyboard / headphone media keys drive the local player.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            player.play()
            self.isPlaying = true
            self.startTimer()
            self.publishTrack()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            player.pause()
            self.isPlaying = false
            self.publishTrack()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }
}
