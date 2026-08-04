import Combine
import Foundation

struct YouTubeSearchResult: Identifiable, Equatable {
    let id: String                  // video id
    let title: String
    let channel: String
    let duration: TimeInterval?
    var url: String { "https://www.youtube.com/watch?v=\(id)" }
    var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
}

/// In-app YouTube search via `yt-dlp --flat-playlist --dump-single-json`.
final class YouTubeSearchService: ObservableObject {
    static let shared = YouTubeSearchService()

    @Published private(set) var results: [YouTubeSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var didTimeOut = false

    private init() {}

    /// Searches `ytsearch20:<query>`; cancels any in-flight search.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let process, process.isRunning { process.terminate() }
        guard let ytDlp = YouTubeDownloadService.locate("yt-dlp") else {
            results = []
            errorMessage = "yt-dlp not found."
            return
        }

        didTimeOut = false
        isSearching = true
        errorMessage = nil
        results = []

        let proc = Process()
        proc.executableURL = ytDlp
        proc.arguments = ["--flat-playlist", "--dump-single-json", "--no-warnings", "ytsearch20:\(trimmed)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard

        var collected = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.append(data) }
        }

        proc.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSearching = false
                self.process = nil
                if proc.terminationStatus == 0 {
                    self.results = Self.parseResults(from: collected)
                } else if self.didTimeOut {
                    self.errorMessage = "Search timed out."
                } else {
                    self.errorMessage = "Search failed (yt-dlp exit \(proc.terminationStatus))."
                }
            }
        }

        process = proc
        do {
            try proc.run()
            // Watchdog: yt-dlp hanging on a dead network must not block the UI forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, let proc = self.process, proc.isRunning else { return }
                self.didTimeOut = true
                proc.terminate()
            }
        } catch {
            isSearching = false
            process = nil
            errorMessage = "Search failed to launch: \(error.localizedDescription)"
        }
    }

    /// Parses `--dump-single-json` output. Entries without an `id` or `title`
    /// are dropped. Verified against real output: entries carry
    /// `id, title, uploader, channel, duration, thumbnails, url`.
    static func parseResults(from data: Data) -> [YouTubeSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let title = entry["title"] as? String, !title.isEmpty else { return nil }
            let channel = (entry["uploader"] as? String) ?? (entry["channel"] as? String) ?? ""
            let duration = entry["duration"] as? Double
            return YouTubeSearchResult(id: id, title: title, channel: channel, duration: duration)
        }
    }
}
