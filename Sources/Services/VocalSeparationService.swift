import AppKit
import Combine
import Foundation

/// Separates the vocals out of a downloaded library track with Demucs
/// (`htdemucs --two-stems=vocals`), storing the instrumental as a sidecar
/// (`Artist - Title.instrumental.mp3`) next to the original. Demucs is
/// optional: when it is absent the app works exactly as before, and Settings
/// offers to install it via `uv tool install demucs`.
///
/// Modeled on `YouTubeDownloadService`: singleton `ObservableObject`, a single
/// `Process` with one shared `Pipe`, `readabilityHandler` progress parsing,
/// and a `terminationHandler` that hops to the main queue.
final class VocalSeparationService: ObservableObject {
    static let shared = VocalSeparationService()

    enum State: Equatable {
        case idle
        case preparing(trackID: String)                    // launched; no progress line yet
        case separating(trackID: String, progress: Double) // 0...100, matching YouTubeDownloadService
        case succeeded(trackID: String)
        case failed(trackID: String, message: String)
    }

    enum Availability: Equatable {
        case ready(URL)        // demucs binary found
        case installable(URL)  // uv found, demucs missing
        case unavailable       // neither
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isInstalling = false
    @Published private(set) var installMessage: String?

    private var process: Process?
    private var outputAccumulator = ""
    /// Karaoke press queued while Demucs installs; separation resumes on success.
    private var pendingAfterInstall: (track: LibraryTrack, autoEnable: Bool)?
    /// Set by `cancel()` so the termination handler reads a user abort as
    /// `.idle` instead of reporting a crash.
    private var wasCancelled = false

    private init() {}

    // MARK: - Availability

    static func availability() -> Availability {
        if let demucs = YouTubeDownloadService.locate("demucs") { return .ready(demucs) }
        if let uv = YouTubeDownloadService.locate("uv") { return .installable(uv) }
        return .unavailable
    }

    /// `Artist - Title.instrumental.mp3` next to the original — always `.mp3`
    /// regardless of the source's extension, since Demucs is run with `--mp3`.
    static func instrumentalURL(for track: LibraryTrack) -> URL {
        track.url
            .deletingPathExtension()
            .appendingPathExtension("instrumental")
            .appendingPathExtension("mp3")
    }

    static func hasInstrumental(for track: LibraryTrack) -> Bool {
        FileManager.default.fileExists(atPath: instrumentalURL(for: track).path)
    }

    /// Parses Demucs' tqdm progress bar (stderr, `\r`-terminated), e.g.
    /// ` 45%|████      | 132.0/292.5 [...]` → 45.
    static func parseProgress(from line: String) -> Double? {
        guard let match = progressRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[range])
    }

    private static let progressRegex = try! NSRegularExpression(pattern: #"(\d{1,3})%"#)

    // MARK: - State queries

    var isBusy: Bool {
        if case .preparing = state { return true }
        if case .separating = state { return true }
        return false
    }

    func isBusy(with track: LibraryTrack) -> Bool {
        if case .preparing(let trackID) = state { return trackID == track.id }
        if case .separating(let trackID, _) = state { return trackID == track.id }
        return false
    }

    /// "42%" once demucs emits a progress line, "Preparing…" during model
    /// download / warm-up.
    var progressLabel: String {
        if case .separating(_, let progress) = state { return "\(Int(progress))%" }
        return "Preparing…"
    }

    // MARK: - Separation

    func separate(_ track: LibraryTrack, autoEnable: Bool = false) {
        guard !isBusy else { return } // single-flight; UI disables the entry while busy

        // Nothing on disk to feed demucs; refuse here so both callers (transport
        // toggle and the row menu) get the same reason instead of "file missing".
        guard track.streamURL == nil else {
            state = .failed(trackID: track.id, message: "Karaoke needs a local file — download this track first.")
            return
        }

        if Self.hasInstrumental(for: track) {
            state = .succeeded(trackID: track.id)
            if autoEnable { AudioPlayerService.shared.enableKaraoke(for: track) }
            return
        }

        switch Self.availability() {
        case .ready(let demucs):
            runSeparation(track, demucs: demucs, autoEnable: autoEnable)
        case .installable:
            // A karaoke press must reach conversion even on a fresh machine:
            // install Demucs first, then separate once it lands. The row stays
            // on "Preparing…" throughout (state covers the install window).
            pendingAfterInstall = (track, autoEnable)
            state = .preparing(trackID: track.id)
            installDemucs()
        case .unavailable:
            state = .failed(trackID: track.id, message: "Demucs not installed — install it from Settings › Karaoke.")
        }
    }

    private func runSeparation(_ track: LibraryTrack, demucs: URL, autoEnable: Bool) {
        wasCancelled = false
        guard FileManager.default.fileExists(atPath: track.url.path) else {
            state = .failed(trackID: track.id, message: "Source file is missing.")
            return
        }

        // Fresh scratch dir per run — never reused, so a stale run can't be
        // picked up by `findNoVocals`.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerstudio-demucs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let args = [
            "--two-stems=vocals", "--mp3", "--mp3-bitrate", "320",
            "-n", "htdemucs", "-o", scratch.path, track.url.path,
        ]

        let proc = Process()
        proc.executableURL = demucs
        proc.arguments = args
        proc.currentDirectoryURL = scratch

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputAccumulator = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self,
                  let text = String(data: data, encoding: .utf8) else { return }
            self.outputAccumulator += text
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            for line in lines {
                let lineStr = String(line)
                if let progress = Self.parseProgress(from: lineStr) {
                    DispatchQueue.main.async {
                        self.state = .separating(trackID: track.id, progress: progress)
                    }
                }
            }
        }

        // No watchdog timeout: separation legitimately runs minutes (≈1.5× the
        // track duration on CPU, plus a one-time model download). `cancel()` is
        // the only interruption path.
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                let cancelled = self.wasCancelled
                self.wasCancelled = false
                if proc.terminationStatus == 0 {
                    guard let noVocals = Self.findNoVocals(in: scratch) else {
                        try? FileManager.default.removeItem(at: scratch)
                        self.state = .failed(trackID: track.id, message: "Separation finished but produced no instrumental.")
                        return
                    }
                    let destination = Self.instrumentalURL(for: track)
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.moveItem(at: noVocals, to: destination)
                        try? FileManager.default.removeItem(at: scratch)
                    } catch {
                        try? FileManager.default.removeItem(at: scratch)
                        Logger.error("Failed to move instrumental into place for \(track.id)", category: "karaoke", error: error)
                        self.state = .failed(trackID: track.id, message: "Could not store the instrumental: \(error.localizedDescription)")
                        return
                    }
                    Logger.info("Instrumental ready for \(track.artist) — \(track.title)", category: "karaoke")
                    self.state = .succeeded(trackID: track.id)
                    if autoEnable { AudioPlayerService.shared.enableKaraoke(for: track) }
                } else {
                    if cancelled {
                        try? FileManager.default.removeItem(at: scratch)
                        self.state = .idle
                        return
                    }
                    // "exit 1" alone is unreadable; demucs' last output lines
                    // carry the actual cause (missing module, bad audio, OOM).
                    let tail = self.outputAccumulator
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .suffix(2)
                        .joined(separator: " ")
                    Logger.error("demucs exit \(proc.terminationStatus): \(tail)", category: "karaoke")
                    try? FileManager.default.removeItem(at: scratch)
                    self.state = .failed(
                        trackID: track.id,
                        message: tail.isEmpty
                            ? "Separation failed (demucs exit \(proc.terminationStatus))."
                            : "Separation failed (exit \(proc.terminationStatus)): \(tail)"
                    )
                }
            }
        }

        Logger.info("Separating vocals from \(track.artist) — \(track.title)", category: "karaoke")
        state = .preparing(trackID: track.id)
        process = proc
        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            state = .failed(trackID: track.id, message: "Failed to launch demucs: \(error.localizedDescription)")
            process = nil
        }
    }

    /// Demucs nests output by model name; locate `no_vocals.mp3` by recursive
    /// search rather than trusting the folder layout.
    private static func findNoVocals(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return e.compactMap { $0 as? URL }.first { $0.lastPathComponent == "no_vocals.mp3" }
    }

    func removeInstrumental(for track: LibraryTrack) {
        if AudioPlayerService.shared.queue.current?.id == track.id {
            AudioPlayerService.shared.setKaraoke(false)
        }
        let instrumental = Self.instrumentalURL(for: track)
        if FileManager.default.fileExists(atPath: instrumental.path) {
            NSWorkspace.shared.recycle([instrumental]) { _, _ in }
        }
        state = .idle
    }

    func cancel() {
        wasCancelled = true
        process?.terminate()
    }

    /// Resets a terminal state so the menu returns to idle.
    func reset() {
        if isBusy { return }
        pendingAfterInstall = nil
        state = .idle
    }

    // MARK: - Installation

    func installDemucs() {
        installDemucs { _ in }
    }

    private func installDemucs(completion: @escaping (Bool) -> Void) {
        guard case .installable(let uv) = Self.availability() else { completion(false); return }

        let proc = Process()
        proc.executableURL = uv
        proc.arguments = ["tool", "install", "demucs"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        var lastLine = ""

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last {
                lastLine = String(line)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isInstalling = false
                let succeeded = proc.terminationStatus == 0
                if succeeded {
                    self.installMessage = nil
                    Logger.info("Demucs installed via uv", category: "karaoke")
                } else {
                    self.installMessage = lastLine
                    Logger.error("uv tool install demucs failed (exit \(proc.terminationStatus)): \(lastLine)", category: "karaoke")
                }
                if let pending = self.pendingAfterInstall {
                    self.pendingAfterInstall = nil
                    if succeeded {
                        switch Self.availability() {
                        case .ready(let demucs):
                            self.runSeparation(pending.track, demucs: demucs, autoEnable: pending.autoEnable)
                        default:
                            // Installed somewhere `locate` does not look.
                            self.state = .failed(trackID: pending.track.id, message: "Demucs installed but could not be found.")
                        }
                    } else {
                        self.state = .failed(
                            trackID: pending.track.id,
                            message: "Demucs install failed: \(self.installMessage ?? "unknown error")"
                        )
                    }
                }
                completion(succeeded)
            }
        }

        Logger.info("Installing Demucs via uv", category: "karaoke")
        isInstalling = true
        installMessage = nil
        do {
            try proc.run()
        } catch {
            isInstalling = false
            installMessage = error.localizedDescription
            if let pending = pendingAfterInstall {
                pendingAfterInstall = nil
                state = .failed(trackID: pending.track.id, message: "Demucs install failed: \(error.localizedDescription)")
            }
            completion(false)
        }
    }
}
