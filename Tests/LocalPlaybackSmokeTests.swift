import XCTest
@testable import PlayerStudio

/// End-to-end smoke of the local playback chain: LibraryService scan →
/// AudioPlayerService play → PlaybackEngine.currentTrack (what every consumer
/// reads) → seek/next/stop. Uses a temp folder so the user's library is
/// untouched; restores settings afterwards.
final class LocalPlaybackSmokeTests: XCTestCase {
    private var tempDir: URL!
    private var originalFolder: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerStudioSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let first = tempDir.appendingPathComponent("Test Artist - First Song.wav")
        let second = tempDir.appendingPathComponent("Test Artist - Second Song.wav")
        try writeTone(to: first)
        try writeTone(to: second)
        // Karaoke sidecar for the first song, at exactly the path
        // `VocalSeparationService.instrumentalURL(for:)` derives. Real (silent)
        // MP3 frames: AVAudioPlayer rejects content/extension mismatches, so a
        // WAV under an .mp3 name would fail the swap.
        let firstTrack = LibraryTrack(
            id: first.path, title: "First Song", artist: "Test Artist",
            album: nil, duration: 10, addedAt: Date(), modifiedAt: Date(), fileSize: 0
        )
        try writeSilentMP3(to: VocalSeparationService.instrumentalURL(for: firstTrack))
        // Deterministic addedAt ordering (addedAt DESC → Second Song first).
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: first.path
        )
        try FileManager.default.setAttributes(
            [.creationDate: Date()],
            ofItemAtPath: second.path
        )

        originalFolder = AppSettings.shared.downloadFolderPath
    }

    override func tearDown() {
        AudioPlayerService.shared.stop()
        AppSettings.shared.downloadFolderPath = originalFolder
        LibraryService.shared.refresh()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLocalPlaybackPublishesToPlaybackEngine() throws {
        let library = LibraryService.shared
        // Let the singleton's launch-time scan (real folder) settle first.
        waitUntil(timeout: 15) { !library.isScanning }

        AppSettings.shared.downloadFolderPath = tempDir.path
        library.refresh()
        waitUntil(timeout: 10) { !library.isScanning && library.tracks.count == 2 }

        guard let first = library.tracks.first(where: { $0.title == "First Song" }),
              let second = library.tracks.first(where: { $0.title == "Second Song" }) else {
            XCTFail("Scanned tracks: \(library.tracks.map(\.title))")
            return
        }
        // WAV has no ID3 tags → filename fallback parses artist/title.
        XCTAssertEqual(first.artist, "Test Artist")
        XCTAssertEqual(second.title, "Second Song")

        let player = AudioPlayerService.shared
        // Library order is addedAt DESC → Second Song first; start there so
        // next() has a real successor (First Song) to advance to.
        let startIndex = library.tracks.firstIndex(where: { $0.id == second.id })!
        player.play(library.tracks, startAt: startIndex)

        XCTAssertTrue(player.isEngaged)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(PlaybackEngine.shared.currentTrack?.title, "Second Song")
        XCTAssertEqual(PlaybackEngine.shared.currentTrack?.artist, "Test Artist")

        // Elapsed advances and the published track follows the local player.
        waitUntil(timeout: 5) { player.elapsed > 0.8 }
        XCTAssertGreaterThan(player.elapsed, 0.8)
        XCTAssertEqual(PlaybackEngine.shared.currentTrack?.title, "Second Song")

        // Seek moves the player (source of truth), not just the published state.
        player.seek(to: 1.5)
        waitUntil(timeout: 2) { abs(player.elapsed - 1.5) < 0.5 }

        // Next advances the queue to First Song (still engaged, still playing).
        player.next()
        XCTAssertTrue(player.isEngaged)
        XCTAssertTrue(player.isPlaying)
        waitUntil(timeout: 3) { PlaybackEngine.shared.currentTrack?.title == "First Song" }
        XCTAssertTrue(player.isPlaying)

        // Stop releases the poll short-circuit and synchronously clears the
        // published track (a later poll may republish external playback —
        // that is the intended resume path).
        player.stop()
        XCTAssertFalse(player.isEngaged)
        XCTAssertNil(PlaybackEngine.shared.currentTrack)
    }

    func testKaraokeSwapPreservesPosition() throws {
        let library = LibraryService.shared
        waitUntil(timeout: 15) { !library.isScanning }

        AppSettings.shared.downloadFolderPath = tempDir.path
        library.refresh()
        waitUntil(timeout: 10) { !library.isScanning && library.tracks.count == 2 }

        guard let first = library.tracks.first(where: { $0.title == "First Song" }) else {
            XCTFail("Scanned tracks: \(library.tracks.map(\.title))")
            return
        }

        let player = AudioPlayerService.shared
        let startIndex = library.tracks.firstIndex(where: { $0.id == first.id })!
        player.play(library.tracks, startAt: startIndex)
        waitUntil(timeout: 5) { player.isPlaying }
        player.seek(to: 4)
        waitUntil(timeout: 2) { abs(player.elapsed - 4) < 0.3 }

        // Toggle on: synchronous swap to the instrumental, position and
        // play state preserved.
        let positionBeforeOn = player.elapsed
        player.setKaraoke(true)
        XCTAssertTrue(player.isKaraokeActive)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.elapsed, positionBeforeOn, accuracy: 0.3)

        // Toggle off: back to the original, position still preserved.
        let positionBeforeOff = player.elapsed
        player.setKaraoke(false)
        XCTAssertFalse(player.isKaraokeActive)
        XCTAssertEqual(player.elapsed, positionBeforeOff, accuracy: 0.3)

        // The sidecar never became a library entry — one row per song.
        XCTAssertEqual(library.tracks.count, 2)
    }

    /// `stop()` (end of queue, repeated failures) drops the player but keeps
    /// the queue; the still-enabled play button must restart the track.
    func testPlayResumesAfterStop() throws {
        let library = LibraryService.shared
        waitUntil(timeout: 15) { !library.isScanning }

        AppSettings.shared.downloadFolderPath = tempDir.path
        library.refresh()
        waitUntil(timeout: 10) { !library.isScanning && library.tracks.count == 2 }

        let player = AudioPlayerService.shared
        player.play(library.tracks, startAt: 0)
        waitUntil(timeout: 5) { player.isPlaying }

        player.stop()
        XCTAssertFalse(player.isEngaged)
        XCTAssertNotNil(player.queue.current)

        player.togglePlayPause()
        XCTAssertTrue(player.isEngaged)
        XCTAssertTrue(player.isPlaying)
        waitUntil(timeout: 5) { player.elapsed > 0.3 }
        XCTAssertGreaterThan(player.elapsed, 0.3)
    }

    /// Browse ▶ tracks have no file to separate: the toggle must refuse with a
    /// reason instead of flipping `isKaraoke` or silently doing nothing.
    func testKaraokeStaysOffForStream() throws {
        let player = AudioPlayerService.shared
        let separation = VocalSeparationService.shared
        defer { separation.reset() }

        let track = LibraryTrack(
            id: "yt:abc123", title: "Streamed", artist: "Remote",
            album: nil, duration: 120, addedAt: Date(), modifiedAt: Date(), fileSize: 0,
            streamURL: URL(string: "https://example.com/a.m4a")!
        )
        player.play([track], startAt: 0)

        player.setKaraoke(true)

        XCTAssertFalse(player.isKaraoke)
        guard case .failed(let trackID, let message) = separation.state else {
            return XCTFail("expected .failed, got \(separation.state)")
        }
        XCTAssertEqual(trackID, track.id)
        XCTAssertTrue(message.contains("local file"), message)

        // Tear the player down before AVPlayer's async failure lands, so the
        // yt: id cannot kick off a real stream refresh mid-suite.
        player.stop()
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// 10 s 440 Hz mono 16-bit PCM WAV (44-byte header + samples). Long enough
    /// that a file never finishes mid-test.
    private func writeTone(to url: URL) throws {
        let sampleRate = 44_100
        let sampleCount = sampleRate * 10
        var data = Data(capacity: 44 + sampleCount * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndian(UInt32(36 + sampleCount * 2)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: littleEndian(UInt16(1)))       // PCM
        data.append(contentsOf: littleEndian(UInt16(1)))       // mono
        data.append(contentsOf: littleEndian(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian(UInt32(sampleRate * 2)))
        data.append(contentsOf: littleEndian(UInt16(2)))       // block align
        data.append(contentsOf: littleEndian(UInt16(16)))      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(sampleCount * 2)))
        for i in 0..<sampleCount {
            let sample = Int16(sin(2 * .pi * 440 * Double(i) / Double(sampleRate)) * 12_000)
            data.append(contentsOf: littleEndian(UInt16(bitPattern: sample)))
        }
        try data.write(to: url)
    }

    /// ~10 s silent MPEG-1 Layer III stream (44.1 kHz, 128 kbps): 417-byte
    /// frames of header + zeroed payload. A real MP3 is required here because
    /// AVAudioPlayer rejects content/extension mismatches, and the karaoke
    /// sidecar path always ends in `.mp3`.
    private func writeSilentMP3(to url: URL) throws {
        var frame = Data(capacity: 417)
        frame.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
        frame.append(Data(count: 413))
        let frames = Int(10_000 / 26.12) + 1   // ≈26.12 ms per frame
        var data = Data(capacity: frames * 417)
        for _ in 0..<frames { data.append(frame) }
        try data.write(to: url)
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}
