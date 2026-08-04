import Foundation

struct NowPlayingInfo {
    let title: String
    let artist: String
    let duration: Double
    let elapsed: Double
    let isPaused: Bool
    let artworkData: Data?
    let artworkId: String?
    /// Bundle id of the app that owns the Now Playing session (e.g. a browser
    /// or YTM Desktop). nil when the helper couldn't resolve it.
    let bundleIdentifier: String?
}

/// Browser-agnostic source backed by the macOS Now Playing system (MediaRemote).
///
/// On macOS 15.4+ Apple restricts MRMediaRemoteGetNowPlayingInfo to Apple-signed
/// callers, so we spawn /usr/bin/swift as a long-running helper that streams
/// JSON lines to us — its signature unblocks the API.
final class NowPlayingService {
    static let shared = NowPlayingService()

    private let lock = NSLock()
    private var latest: [String: Any] = [:]
    private var latestUpdatedAt: Date = .distantPast
    private var helperProcess: Process?
    private let restartQueue = DispatchQueue(label: "com.playerstudio.nowplaying.restart")

    private init() {}

    func start() {
        spawnHelper()
    }

    private func spawnHelper() {
        guard let scriptURL = Bundle.main.url(forResource: "now_playing_helper", withExtension: "swift") else {
            Logger.error("now_playing_helper.swift missing from Resources", category: "playback")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [scriptURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] _ in
            Logger.info("NowPlaying helper exited; restarting in 2s", category: "playback")
            self?.restartQueue.asyncAfter(deadline: .now() + 2) {
                self?.spawnHelper()
            }
        }

        do {
            try process.run()
        } catch {
            Logger.error("Failed to spawn NowPlaying helper", category: "playback", error: error)
            return
        }

        helperProcess = process
        Logger.info("NowPlaying helper spawned (pid=\(process.processIdentifier))", category: "playback")

        readLines(from: stdoutPipe.fileHandleForReading) { [weak self] line in
            self?.handleLine(line)
        }
        readLines(from: stderrPipe.fileHandleForReading) { line in
            if !line.isEmpty {
                Logger.error("NowPlaying helper stderr: \(line)", category: "playback")
            }
        }
    }

    private func readLines(from handle: FileHandle, onLine: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while autoreleasepool(invoking: {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return false }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: 0..<nl)
                    buffer.removeSubrange(0...nl)
                    if let line = String(data: lineData, encoding: .utf8) {
                        onLine(line)
                    }
                }
                return true
            }) {}
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        lock.lock()
        latest = dict
        latestUpdatedAt = Date()
        lock.unlock()
    }

    /// True if the helper has produced any line in the last 10s — meaning
    /// MediaRemote is functional and we can skip browser-specific scraping.
    func isStreaming() -> Bool {
        lock.lock()
        let updatedAt = latestUpdatedAt
        lock.unlock()
        return Date().timeIntervalSince(updatedAt) < 10
    }

    func currentInfo() -> NowPlayingInfo? {
        lock.lock()
        let dict = latest
        let updatedAt = latestUpdatedAt
        lock.unlock()

        guard let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        // If helper hasn't updated in >15s assume stale.
        if Date().timeIntervalSince(updatedAt) > 15 {
            return nil
        }
        let artist = (dict["artist"] as? String) ?? ""
        let duration = (dict["duration"] as? Double) ?? 0
        let rawElapsed = (dict["elapsed"] as? Double) ?? 0
        let isPlaying = (dict["isPlaying"] as? Bool) ?? false
        let timestamp = (dict["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let artworkData: Data? = {
            guard let b64 = dict["artwork"] as? String else { return nil }
            return Data(base64Encoded: b64)
        }()
        let artworkId = dict["artworkId"] as? String

        var elapsed = rawElapsed
        if isPlaying, let ts = timestamp {
            elapsed = max(0, rawElapsed + Date().timeIntervalSince(ts))
        }
        if duration > 0 {
            elapsed = min(duration, elapsed)
        }

        return NowPlayingInfo(
            title: title,
            artist: artist,
            duration: duration,
            elapsed: elapsed,
            isPaused: !isPlaying,
            artworkData: artworkData,
            artworkId: artworkId,
            bundleIdentifier: dict["bundleId"] as? String
        )
    }
}
