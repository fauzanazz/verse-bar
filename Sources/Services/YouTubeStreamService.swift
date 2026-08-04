import AppKit
import Combine
import Foundation

/// Resolves a YouTube video's direct audio URL with `yt-dlp -g` and plays it as
/// a remote stream. Nothing is written to disk, so playing a track from Browse
/// never costs a download.
final class YouTubeStreamService: ObservableObject {
    static let shared = YouTubeStreamService()

    @Published private(set) var resolvingID: String?
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var didTimeOut = false

    private init() {}

    /// Stream resolution failures carry a user-facing Indonesian message.
    enum StreamResolveError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    /// AAC-in-MP4 only: AVFoundation cannot decode YouTube's Opus/WebM audio.
    static let formatSelector = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

    /// yt-dlp may print warnings before the URL — take the last `https://` line.
    static func parseStreamURL(from output: String) -> URL? {
        output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("https://") }
            .flatMap { URL(string: $0) }
    }

    /// Resolves and plays a Browse result as a remote stream. Stream track
    /// identity is `"yt:<videoID>"` — never the googlevideo URL, which expires.
    func play(_ result: YouTubeSearchResult) {
        resolvingID = result.id
        errorMessage = nil
        resolve(videoID: result.id) { [weak self] outcome in
            guard let self else { return }
            self.resolvingID = nil
            switch outcome {
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            case .success(let url):
                let track = LibraryTrack(
                    id: "yt:\(result.id)", title: result.title, artist: result.channel,
                    album: nil, duration: result.duration ?? 0, addedAt: Date(),
                    modifiedAt: Date(), fileSize: 0, streamURL: url
                )
                AudioPlayerService.shared.play([track], startAt: 0)
                self.fetchArtwork(result.thumbnailURL, for: track.id)
            }
        }
    }

    /// Silent mid-playback repair: re-resolves an expired stream URL. Does not
    /// touch `resolvingID`/`errorMessage`.
    func refreshStream(for track: LibraryTrack, completion: @escaping (URL?) -> Void) {
        guard let videoID = track.youtubeID else { completion(nil); return }
        resolve(videoID: videoID) { result in
            completion(try? result.get())
        }
    }

    private func fetchArtwork(_ url: URL, for trackID: String) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                LibraryService.shared.cacheArtwork(image, for: trackID)
                AudioPlayerService.shared.refreshArtwork(for: trackID)
            }
        }.resume()
    }

    /// Runs `yt-dlp -f <selector> -g` and returns the first URL on stdout.
    /// Cancels any in-flight resolve; watchdogged so a dead network can't hold
    /// the ▶ spinner forever.
    private func resolve(videoID: String, completion: @escaping (Result<URL, Error>) -> Void) {
        if let process, process.isRunning { process.terminate() }
        guard let ytDlp = YouTubeDownloadService.locate("yt-dlp") else {
            completion(.failure(StreamResolveError.message("yt-dlp not found.")))
            return
        }

        didTimeOut = false
        let proc = Process()
        proc.executableURL = ytDlp
        proc.arguments = [
            "-f", Self.formatSelector, "-g", "--no-playlist", "--no-warnings",
            "https://www.youtube.com/watch?v=\(videoID)",
        ]
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
                if self.didTimeOut {
                    completion(.failure(StreamResolveError.message("Timed out resolving stream URL.")))
                } else if proc.terminationStatus == 0,
                          let url = Self.parseStreamURL(
                              from: String(data: collected, encoding: .utf8) ?? ""
                          ) {
                    completion(.success(url))
                } else if proc.terminationStatus == 0 {
                    completion(.failure(StreamResolveError.message("Tidak ada audio AAC untuk video ini — pakai ➕ untuk download.")))
                } else {
                    completion(.failure(StreamResolveError.message("Gagal mengambil stream (yt-dlp exit \(proc.terminationStatus)).")))
                }
            }
        }

        process = proc
        do {
            try proc.run()
            // Watchdog: yt-dlp hanging on a dead network must not block playback
            // forever (matches the 25 s watchdog in YouTubeSearchService).
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let proc = self.process, proc.isRunning else { return }
                self.didTimeOut = true
                proc.terminate()
            }
        } catch {
            completion(.failure(StreamResolveError.message("Stream resolve failed to launch: \(error.localizedDescription)")))
        }
    }
}
