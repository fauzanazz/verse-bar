import Combine
import Foundation

/// Downloads YouTube tracks as MP3 via `yt-dlp` + `ffmpeg`, sequentially.
///
/// Binaries are shelled out through `Process` and located in the app bundle's
/// Resources first, then well-known install paths, then `$PATH`.
final class YouTubeDownloadService: ObservableObject {
    static let shared = YouTubeDownloadService()

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case succeeded(fileURL: URL)
        case failed(message: String)
    }

    struct QueuedDownload: Identifiable, Equatable {
        let id: String        // video id, or "np:" + track.syncOffsetKey for the popover path
        let title: String
        let artist: String
        let target: String    // "https://www.youtube.com/watch?v=…" or "ytsearch1:Artist - Title"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var pending: [QueuedDownload] = []
    @Published private(set) var activeID: String?
    @Published private(set) var finishedIDs: Set<String> = []

    private var process: Process?
    private var outputAccumulator = ""
    private var finalOutputPath: String?

    private init() {}

    /// Resolves a binary (yt-dlp / ffmpeg) the same way the release app does:
    /// bundled in Resources, Homebrew, /usr/local, then $PATH.
    static func locate(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name) {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ])
        // `uv tool install` lands binaries here; Finder-launched apps inherit
        // a minimal PATH that never includes it.
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/\(name)")
        )
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(name))
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Parses yt-dlp's `--newline` progress lines, e.g. `[download]  45.3% of 3.4MiB at ...`.
    static func parseProgress(from line: String) -> Double? {
        guard let match = progressRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[range])
    }

    private static let progressRegex = try! NSRegularExpression(pattern: #"\[download\]\s+([\d.]+)%"#)

    var isAvailable: Bool {
        Self.locate("yt-dlp") != nil && Self.locate("ffmpeg") != nil
    }

    /// Popover path: download whatever is playing. A Browse stream downloads that
    /// exact video (and shares the Browse row's id, so the two entry points can
    /// never queue the same song twice); anything else resolves by search.
    func download(_ track: Track) {
        if let current = AudioPlayerService.shared.queue.current,
           let videoID = current.youtubeID {
            enqueue(QueuedDownload(id: videoID, title: current.title, artist: current.artist,
                                   target: "https://www.youtube.com/watch?v=\(videoID)"))
            return
        }
        enqueue(QueuedDownload(id: "np:" + track.syncOffsetKey, title: track.title,
                               artist: track.artist,
                               target: "ytsearch1:\(track.artist) - \(track.title)"))
    }

    /// Appends to the queue and starts the pump when idle. Single-flight is
    /// guaranteed: `start` is only ever called from the pump.
    func enqueue(_ item: QueuedDownload) {
        // Same song already downloading or queued (Browse ➕ and the popover ⬇
        // can both reach it): drop the duplicate.
        guard item.id != activeID, !pending.contains(where: { $0.id == item.id }) else { return }
        pending.append(item)
        if activeID == nil {
            start(pending[0])
        }
    }

    /// Resets a terminal state so the button returns to idle (e.g. after the
    /// success indicator has been shown for a few seconds).
    func reset() {
        if case .downloading = state { return }
        state = .idle
    }

    private func start(_ item: QueuedDownload) {
        guard let ytDlp = Self.locate("yt-dlp") else {
            state = .failed(message: "yt-dlp not found — install with: brew install yt-dlp")
            pumpNext()
            return
        }
        guard let ffmpeg = Self.locate("ffmpeg") else {
            state = .failed(message: "ffmpeg not found — install with: brew install ffmpeg")
            pumpNext()
            return
        }

        let folder = AppSettings.shared.downloadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // `--print after_move:filepath` emits the final path on the last stdout
        // line. `%(artist,uploader)s` avoids the "NA - …" filenames YouTube
        // uploads produce when no artist tag exists; `--parse-metadata` ensures
        // the embedded ID3 artist tag is always populated for the library index.
        let args = [
            "-x", "--audio-format", "mp3", "--audio-quality", "0",
            "--embed-metadata", "--embed-thumbnail",
            "--no-playlist", "--newline",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "--print", "after_move:filepath",
            "--parse-metadata", "%(artist,uploader)s:%(meta_artist)s",
            "-o", folder.appendingPathComponent("%(artist,uploader)s - %(title)s.%(ext)s").path,
            item.target,
        ]

        let proc = Process()
        proc.executableURL = ytDlp
        proc.arguments = args
        proc.currentDirectoryURL = folder

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputAccumulator = ""
        finalOutputPath = nil

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
                        self.state = .downloading(progress: progress)
                    }
                } else if lineStr.hasSuffix(".mp3") {
                    self.finalOutputPath = lineStr
                }
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus == 0 {
                    let url = self.finalOutputPath
                        .map { URL(fileURLWithPath: $0) }
                        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                        ?? Self.newestMP3(in: folder)
                    if let url {
                        Logger.info("Downloaded \(item.title) → \(url.path)", category: "download")
                        self.state = .succeeded(fileURL: url)
                        self.finishedIDs.insert(item.id)
                        LibraryService.shared.refresh()
                    } else {
                        self.state = .failed(message: "Download finished but no MP3 was produced.")
                    }
                } else {
                    let tail = self.outputAccumulator.split(separator: "\n").suffix(2).joined(separator: " | ")
                    Logger.error("yt-dlp exit \(proc.terminationStatus): \(tail)", category: "download")
                    self.state = .failed(message: "Download failed (yt-dlp exit \(proc.terminationStatus)).")
                }
                self.process = nil
                self.activeID = nil
                self.pending.removeFirst()
                self.pumpNext()
            }
        }

        Logger.info("Starting download of \(item.artist) - \(item.title)", category: "download")
        activeID = item.id
        state = .downloading(progress: 0)
        process = proc
        do {
            try proc.run()
        } catch {
            state = .failed(message: "Failed to launch yt-dlp: \(error.localizedDescription)")
            process = nil
            activeID = nil
            pending.removeFirst()
            pumpNext()
        }
    }

    private func pumpNext() {
        if let next = pending.first {
            start(next)
        }
    }

    private static func newestMP3(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .max { ($0.contentModificationDate ?? .distantPast) < ($1.contentModificationDate ?? .distantPast) }
    }
}

private extension URL {
    var contentModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
