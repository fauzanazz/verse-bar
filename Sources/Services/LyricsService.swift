import Foundation
import Combine

/// Outcome of a lyrics lookup. Drives UI without polluting `lyricLines` with
/// fake placeholder rows — the menu bar shows none of these, only the popup.
enum LyricsStatus: Equatable {
    case idle              // no track / not started
    case searching         // fetch in flight
    case found             // synced lyrics loaded
    case plainFound        // full unsynced lyrics loaded
    case notFound          // no synced lyrics for this track
    case unavailableOffline
    case error             // network / parse failure
    case normalizing       // LLM fallback is extracting original metadata
}

enum LyricsSelectionError: Error {
    case trackChanged
    case unusableResult
}

class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published var lyricLines: [LyricLine] = []
    @Published var plainLyrics: String?
    @Published var currentLineIndex: Int?
    @Published var currentWordIndex: Int?
    @Published var currentWordFraction: Double = 0
    @Published var isFetching = false
    @Published var offlineMode = false
    /// Lookup outcome for the current track. The menu bar never renders this —
    /// "not found" etc. is surfaced only in the popup.
    @Published var status: LyricsStatus = .idle
    
    private var playbackEngine = PlaybackEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var syncTimer: Timer?
    private var modelFallbackTask: URLSessionDataTask?
    private var modelFallbackID: UUID?
    
    private var lastTrackTitle = ""
    private var lastTrackArtist = ""
    private lazy var metadataCache = LyricsMetadataCache(
        databaseURL: cacheDirectory.appendingPathComponent("MetadataCache.sqlite3")
    )
    
    private let cacheDirectory: URL
    
    private init() {
        // Resolve local cache directory
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportDir = paths[0].appendingPathComponent("com.playerstudio.PlayerStudio", isDirectory: true)
        self.cacheDirectory = appSupportDir.appendingPathComponent("LyricsCache", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            Logger.error("Failed to create lyrics cache directory", category: "lyrics", error: error)
        }
        
        // Listen to track changes from PlaybackEngine
        playbackEngine.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.handleTrackChanged(track)
            }
            .store(in: &cancellables)
            
        // Start high-precision interpolation timer
        startSyncTimer()
    }
    
    private func handleTrackChanged(_ track: Track?) {
        guard let track = track else {
            stopModelFallback()
            self.lyricLines = []
            self.plainLyrics = nil
            self.currentLineIndex = nil
            self.currentWordIndex = nil
            self.currentWordFraction = 0
            self.status = .idle
            self.lastTrackTitle = ""
            self.lastTrackArtist = ""
            return
        }

        // Only fetch if track title or artist has changed
        if track.title == lastTrackTitle && track.artist == lastTrackArtist {
            return
        }
        stopModelFallback()

        self.lastTrackTitle = track.title
        self.lastTrackArtist = track.artist
        self.lyricLines = []
        self.plainLyrics = nil
        self.currentLineIndex = nil
        self.currentWordIndex = nil
        self.currentWordFraction = 0
        self.status = .searching
        
        Logger.info("📀 Fetching lyrics for: \(track.title) - \(track.artist)", category: "lyrics")
        fetchLyrics(for: track)
    }
    
    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateActiveLyricIndex()
        }
    }
    
    private func updateActiveLyricIndex() {
        guard let track = playbackEngine.currentTrack, !lyricLines.isEmpty else {
            if currentLineIndex != nil {
                currentLineIndex = nil
            }
            if currentWordIndex != nil {
                currentWordIndex = nil
            }
            if currentWordFraction != 0 {
                currentWordFraction = 0
            }
            return
        }
        
        let elapsed = track.currentProgress + AppSettings.shared.manualSyncOffset(for: track)
        
        // Find current line (last line whose timestamp <= elapsed)
        var foundIndex: Int?
        for (index, line) in lyricLines.enumerated() {
            if line.timestamp <= elapsed {
                foundIndex = index
            } else {
                break
            }
        }
        
        if currentLineIndex != foundIndex {
            currentLineIndex = foundIndex
        }

        var wordIndex: Int?
        var fraction: Double = 0
        if let index = foundIndex {
            let words = lyricLines[index].words
            wordIndex = words.lastIndex(where: { $0.start <= elapsed })
            if let w = wordIndex {
                let word = words[w]
                let span = max(word.end - word.start, 0.001)
                let raw = min(max((elapsed - word.start) / span, 0), 1)
                // ponytail: kuantisasi ke jumlah karakter kata — nilai antara tidak
                // terlihat, dan ini menahan @Published dari 20 update/detik.
                let steps = Double(max(word.text.count, 1))
                fraction = (raw * steps).rounded(.down) / steps
            }
        }
        if currentWordIndex != wordIndex {
            currentWordIndex = wordIndex
        }
        if currentWordFraction != fraction {
            currentWordFraction = fraction
        }
    }
    
    // MARK: - Lyrics Fetching & Caching
    private func fetchLyrics(for track: Track) {
        let slug = getCacheSlug(artist: track.artist, title: track.title)
        let cacheFile = cacheDirectory.appendingPathComponent("\(slug).json")

        let manualFile = manualSelectionFile(for: track)
        if FileManager.default.fileExists(atPath: manualFile.path) {
            do {
                let data = try Data(contentsOf: manualFile)
                let result = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
                guard hasUsableLyrics(result) else {
                    throw LyricsSelectionError.unusableResult
                }
                _ = applySearchResult(result, for: track)
                Logger.info("Loaded manually selected lyrics for \(track.title)", category: "lyrics")
                return
            } catch {
                Logger.error("Failed to load manually selected lyrics", category: "lyrics", error: error)
            }
        }
        
        // Try Cache first
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            do {
                let data = try Data(contentsOf: cacheFile)
                let lines = try JSONDecoder().decode([CachedLyricLine].self, from: data)
                self.lyricLines = lines.map { cached in
                    if let words = cached.words, !words.isEmpty {
                        // Timing asli tersimpan di cache — pakai langsung.
                        return LyricLine(
                            timestamp: cached.timestamp,
                            text: cached.text,
                            romanized: cached.romanized ?? Self.romanize(cached.text),
                            words: words.map {
                                LyricWord(text: $0.text, romanized: $0.romanized, start: $0.start, end: $0.end, joinsNext: $0.joinsNext ?? false)
                            }
                        )
                    }
                    // Cache lama tanpa words → estimasi ulang.
                    return LyricLine.makeLines([
                        LyricLine.RawEntry(timestamp: cached.timestamp, body: cached.text, romanized: cached.romanized)
                    ])[0]
                }
                self.status = self.lyricLines.isEmpty ? .notFound : .found
                Logger.info("✅ Loaded cached lyrics for \(track.title) (\(self.lyricLines.count) lines)", category: "lyrics")
                return
            } catch {
                Logger.error("Failed to load cached lyrics", category: "lyrics", error: error)
            }
        }
        
        // Offline check
        if offlineMode {
            self.lyricLines = []
            self.status = .unavailableOffline
            return
        }
        
        // Apple Music syllable data first; LRCLIB exact get as fallback.
        self.isFetching = true
        AppleLyricsService.fetch(title: track.title, artist: track.artist, duration: track.duration) { [weak self] lines in
            guard let self else { return }
            guard self.isCurrentTrack(track) else { return }
            guard let lines, !lines.isEmpty else {
                self.fetchFromLRCLIB(track: track, cacheFile: cacheFile)
                return
            }
            self.isFetching = false
            self.lyricLines = lines
            self.plainLyrics = nil
            self.status = .found
            self.updateActiveLyricIndex()
            self.cacheLines(lines, to: cacheFile)
            Logger.info("✅ Apple syllable lyrics for \(track.title) (\(lines.count) lines)", category: "lyrics")
        }
    }

    private func fetchFromLRCLIB(track: Track, cacheFile: URL) {
        // If the artist is generic, skip exact get and go to search fallback
        if track.artist == "Unknown Artist" || track.artist == "YouTube Music" || track.artist == "YouTube" {
            self.isFetching = true
            self.fetchFallback(track: track)
            return
        }
        
        // Fetch from LRCLIB using exact get
        self.isFetching = true
        let encodedTitle = track.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedArtist = track.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let durationParam = track.duration > 0 ? "&duration=\(Int(track.duration))" : ""
        
        guard let url = URL(string: "https://lrclib.net/api/get?artist_name=\(encodedArtist)&track_name=\(encodedTitle)\(durationParam)") else {
            self.isFetching = false
            return
        }
        
        Logger.info("🌐 Fetching from LRCLIB: \(url.absoluteString)", category: "lyrics")
        
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("PlayerStudio/1.0 (https://github.com/antikode/verse-bar)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                Logger.error("Failed to fetch lyrics from LRCLIB", category: "lyrics", error: error)
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.fetchFallback(track: track)
                }
                return
            }
            
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.info("LRCLIB exact get returned status \(statusCode), trying search fallback", category: "lyrics")
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.fetchFallback(track: track)
                }
                return
            }
            
            do {
                let responseObj = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
                if let syncedLyrics = responseObj.syncedLyrics, !syncedLyrics.isEmpty {
                    self.parseAndCacheResponse(data, track: track, cacheFile: cacheFile)
                } else {
                    Logger.info("LRCLIB exact get had no synced lyrics, trying search fallback", category: "lyrics")
                    DispatchQueue.main.async {
                        self.fetchFallback(track: track)
                    }
                }
            } catch {
                Logger.error("Failed to decode LRCLIB exact response", category: "lyrics", error: error)
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.status = .error
                }
            }
        }.resume()
    }
    
    private func fetchFallback(track: Track) {
        // Try searching. If artist is generic, search ONLY for the song title!
        let query: String
        if track.artist == "Unknown Artist" || track.artist == "YouTube Music" || track.artist == "YouTube" {
            query = track.title
        } else {
            query = "\(track.title) \(track.artist)"
        }
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        guard let url = URL(string: "https://lrclib.net/api/search?q=\(encodedQuery)") else {
            self.isFetching = false
            return
        }
        
        Logger.info("🔍 LRCLIB search fallback: \(url.absoluteString)", category: "lyrics")
        
        self.isFetching = true
        
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("PlayerStudio/1.0 (https://github.com/antikode/verse-bar)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            
            if let error = error {
                self.handleSearchFallbackFailure(
                    track: track,
                    message: "LRCLIB search fallback request failed",
                    error: error
                )
                return
            }

            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.handleSearchFallbackFailure(
                    track: track,
                    message: "LRCLIB search fallback returned status \(statusCode)"
                )
                return
            }
            
            do {
                let searchResults = try JSONDecoder().decode([LRCLIBResponse].self, from: data)
                Logger.info("🔍 Search returned \(searchResults.count) results", category: "lyrics")
                
                // Look for the first result that actually has synced lyrics
                if let bestMatch = searchResults.first(where: { $0.syncedLyrics != nil && !($0.syncedLyrics?.isEmpty ?? true) }) {
                    let cacheFile = self.cacheDirectory.appendingPathComponent("\(self.getCacheSlug(artist: track.artist, title: track.title)).json")
                    
                    if let rawData = try? JSONEncoder().encode(bestMatch) {
                        self.parseAndCacheResponse(rawData, track: track, cacheFile: cacheFile)
                        
                        // Update PlaybackEngine with the real artist name!
                        if let realArtist = bestMatch.artistName, (track.artist == "Unknown Artist" || track.artist == "YouTube Music" || track.artist == "YouTube") {
                            DispatchQueue.main.async {
                                PlaybackEngine.shared.resolveTrackMetadata(title: track.title, artist: realArtist)
                            }
                        }
                    }
                } else if let query = self.coverFallbackQuery(for: track) {
                    Logger.info("No synced lyrics found; trying cover fallback with query: \(query)", category: "lyrics")
                    DispatchQueue.main.async {
                        self.fetchCoverLyrics(track: track, query: query)
                    }
                } else {
                    Logger.info("No synced lyrics found in search results", category: "lyrics")
                    DispatchQueue.main.async {
                        self.lyricLines = []
                        self.status = .notFound
                        self.isFetching = false
                    }
                }
            } catch {
                self.handleSearchFallbackFailure(
                    track: track,
                    message: "Failed to decode LRCLIB search fallback",
                    error: error
                )
            }
        }.resume()
    }

    private func handleSearchFallbackFailure(
        track: Track,
        message: String,
        error: Error? = nil,
        allowModelFallback: Bool = true
    ) {
        Logger.error(message, category: "lyrics", error: error)
        DispatchQueue.main.async {
            guard self.isCurrentTrack(track) else { return }
            self.plainLyrics = nil
            self.lyricLines = []
            self.currentLineIndex = nil
            self.currentWordIndex = nil
            self.currentWordFraction = 0

            if allowModelFallback, let query = self.coverFallbackQuery(for: track) {
                Logger.info("LRCLIB search fallback failed; trying model normalization", category: "lyrics")
                self.fetchModelNormalizedLyrics(track: track, previousQuery: query)
            } else {
                self.status = .error
                self.isFetching = false
            }
        }
    }
    
    private func coverFallbackQuery(for track: Track) -> String? {
        let markers = ["cover", "acoustic", "karaoke", "live"]
        let lowercasedTitle = track.title.lowercased()
        guard track.title.contains("|") || markers.contains(where: lowercasedTitle.contains) else {
            return nil
        }

        var query = String(track.title.split(separator: "|", maxSplits: 1).first ?? "")
        let pattern = #"\([^)]*(?:cover|acoustic|karaoke|live)[^)]*\)|\[[^\]]*(?:cover|acoustic|karaoke|live)[^\]]*\]"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            query = regex.stringByReplacingMatches(
                in: query,
                range: NSRange(query.startIndex..., in: query),
                withTemplate: ""
            )
        }
        return query
            .replacingOccurrences(of: " - ", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func fetchCoverLyrics(track: Track, query: String, allowModelFallback: Bool = true) {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://lrclib.net/api/search?q=\(encodedQuery)") else {
            isFetching = false
            status = .error
            return
        }

        isFetching = true
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("PlayerStudio/1.0 (https://github.com/antikode/verse-bar)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            guard error == nil,
                  let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.handleSearchFallbackFailure(
                    track: track,
                    message: "Cover lyrics search returned status \(statusCode)",
                    error: error,
                    allowModelFallback: allowModelFallback
                )
                return
            }

            do {
                let results = try JSONDecoder().decode([LRCLIBResponse].self, from: data)
                let result = results.first(where: {
                    $0.syncedLyrics != nil && !($0.syncedLyrics?.isEmpty ?? true)
                }) ?? results.first(where: {
                    !($0.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                })

                DispatchQueue.main.async {
                    guard self.isCurrentTrack(track) else { return }
                    if let result {
                        _ = self.applySearchResult(result, for: track)
                        Logger.info("Loaded cover lyrics: \(track.title)", category: "lyrics")
                    } else if allowModelFallback {
                        self.fetchModelNormalizedLyrics(track: track, previousQuery: query)
                    } else {
                        self.plainLyrics = nil
                        self.lyricLines = []
                        self.currentLineIndex = nil
                        self.currentWordIndex = nil
                        self.currentWordFraction = 0
                        self.status = .notFound
                        self.isFetching = false
                    }
                }
            } catch {
                self.handleSearchFallbackFailure(
                    track: track,
                    message: "Failed to decode cover lyrics search results",
                    error: error,
                    allowModelFallback: allowModelFallback
                )
            }
        }.resume()
    }

    func cancelModelFallback() {
        guard isUsingModelFallback else { return }
        stopModelFallback()
        isFetching = false
        status = .notFound
        Logger.info("LLM lyrics fallback cancelled by user", category: "lyrics")
    }

    @Published private(set) var isUsingModelFallback = false

    private func stopModelFallback() {
        modelFallbackTask?.cancel()
        modelFallbackTask = nil
        modelFallbackID = nil
        isUsingModelFallback = false
    }

    private func fetchModelNormalizedLyrics(track: Track, previousQuery: String) {
        if let cached = metadataCache.lookup(title: track.title, artist: track.artist) {
            Logger.info(
                cached.isFuzzyMatch ? "Using fuzzy metadata cache match: \(cached.query)" : "Using exact metadata cache match: \(cached.query)",
                category: "lyrics"
            )
            if cached.query.caseInsensitiveCompare(previousQuery) == .orderedSame {
                status = .notFound
                isFetching = false
            } else {
                fetchCoverLyrics(track: track, query: cached.query, allowModelFallback: false)
            }
            return
        }

        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else {
            status = .notFound
            isFetching = false
            return
        }

        let prompt = """
        Video title: \(track.title)
        Channel: \(track.artist)
        """
        let body: [String: Any] = [
            "model": "gpt-oss:120b-cloud",
            "stream": false,
            "think": false,
            "format": "json",
            "messages": [
                [
                    "role": "system",
                    "content": "Extract original song metadata from a noisy cover video. Return one JSON object with exactly these keys: track, artist. No other keys or text. The channel is usually the uploader, not the artist."
                ],
                ["role": "user", "content": prompt]
            ],
            "options": ["temperature": 0]
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: body) else {
            status = .notFound
            isFetching = false
            return
        }

        Logger.info("Asking Ollama Cloud to normalize cover metadata: \(track.title)", category: "lyrics")
        isUsingModelFallback = true
        status = .normalizing
        let requestID = UUID()
        modelFallbackID = requestID

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = requestData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            do {
                if let error = error { throw error }
                guard let data = data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                let chat = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                let normalizedData = Data(chat.message.content.utf8)
                let normalized = try JSONDecoder().decode(OllamaNormalizedTrack.self, from: normalizedData)
                let artist = normalized.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = normalized.track.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !artist.isEmpty, !title.isEmpty else {
                    throw URLError(.cannotParseResponse)
                }
                let query = "\(artist) \(title)"

                DispatchQueue.main.async {
                    guard self.modelFallbackID == requestID, self.isCurrentTrack(track) else { return }
                    self.modelFallbackTask = nil
                    self.modelFallbackID = nil
                    self.isUsingModelFallback = false
                    guard query.caseInsensitiveCompare(previousQuery) != .orderedSame else {
                        self.status = .notFound
                        self.isFetching = false
                        return
                    }
                    self.metadataCache.store(
                        sourceTitle: track.title,
                        sourceArtist: track.artist,
                        normalizedTrack: title,
                        normalizedArtist: artist
                    )
                    Logger.info("Ollama normalized cover metadata: \(query)", category: "lyrics")
                    self.fetchCoverLyrics(track: track, query: query, allowModelFallback: false)
                }
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                Logger.error("Ollama cover metadata fallback failed", category: "lyrics", error: error)
                DispatchQueue.main.async {
                    guard self.modelFallbackID == requestID, self.isCurrentTrack(track) else { return }
                    self.stopModelFallback()
                    self.status = .notFound
                    self.isFetching = false
                }
            }
        }
        modelFallbackTask = task
        task.resume()
    }

    private func isCurrentTrack(_ track: Track) -> Bool {
        lastTrackTitle == track.title && lastTrackArtist == track.artist
    }

    func searchLyrics(
        matching query: String,
        completion: @escaping (Result<[LRCLIBResponse], Error>) -> Void
    ) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion(.success([]))
            return
        }

        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(
            "PlayerStudio/1.0 (https://github.com/antikode/verse-bar)",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<[LRCLIBResponse], Error>
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                result = .failure(URLError(.badServerResponse))
            } else if let data {
                do {
                    result = .success(try JSONDecoder().decode([LRCLIBResponse].self, from: data))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(URLError(.zeroByteResource))
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }

    private func applySearchResult(_ result: LRCLIBResponse, for track: Track) -> Bool {
        if let syncedLyrics = result.syncedLyrics {
            let parsedLines = parseLRC(syncedLyrics)
            if !parsedLines.isEmpty {
                isFetching = false
                lyricLines = parsedLines
                plainLyrics = nil
                status = .found
                updateActiveLyricIndex()
                return true
            }
        }

        if let plainLyrics = result.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plainLyrics.isEmpty {
            isFetching = false
            lyricLines = []
            currentLineIndex = nil
            currentWordIndex = nil
            currentWordFraction = 0
            self.plainLyrics = plainLyrics
            status = .plainFound
            return true
        }

        return false
    }

    private func hasUsableLyrics(_ result: LRCLIBResponse) -> Bool {
        if let syncedLyrics = result.syncedLyrics, !parseLRC(syncedLyrics).isEmpty {
            return true
        }
        return !(result.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func useSearchResult(_ result: LRCLIBResponse, for track: Track) throws {
        guard playbackEngine.currentTrack?.syncOffsetKey == track.syncOffsetKey else {
            throw LyricsSelectionError.trackChanged
        }
        guard hasUsableLyrics(result) else {
            throw LyricsSelectionError.unusableResult
        }

        let data = try JSONEncoder().encode(result)
        try data.write(to: manualSelectionFile(for: track), options: .atomic)
        _ = applySearchResult(result, for: track)
    }

    private func parseAndCacheResponse(_ data: Data, track: Track, cacheFile: URL) {
        do {
            let responseObj = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            let syncedContent = responseObj.syncedLyrics ?? ""
            let parsedLines = parseLRC(syncedContent)

            DispatchQueue.main.async {
                self.isFetching = false
                if parsedLines.isEmpty {
                    self.lyricLines = []
                    self.status = .notFound
                    Logger.info("⚠️ Parsed 0 lines from synced lyrics content", category: "lyrics")
                } else {
                    self.lyricLines = parsedLines
                    self.status = .found
                    Logger.info("✅ Loaded \(parsedLines.count) lyric lines for \(track.title)", category: "lyrics")
                    self.cacheLines(parsedLines, to: cacheFile)
                }
            }
        } catch {
            Logger.error("Failed to decode LRCLIB response", category: "lyrics", error: error)
            DispatchQueue.main.async {
                self.isFetching = false
                self.lyricLines = []
                self.status = .error
            }
        }
    }

    private func cacheLines(_ lines: [LyricLine], to cacheFile: URL) {
        let cached = lines.map {
            CachedLyricLine(timestamp: $0.timestamp, text: $0.text, romanized: $0.romanized,
                            words: $0.words.map {
                                CachedLyricWord(text: $0.text, romanized: $0.romanized,
                                                start: $0.start, end: $0.end, joinsNext: $0.joinsNext)
                            })
        }
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheFile)
            Logger.info("💾 Saved cached lyrics", category: "lyrics")
        }
    }
    
    // MARK: - LRC File Parser
    private func parseLRC(_ lrcContent: String) -> [LyricLine] {
        guard !lrcContent.isEmpty else { return [] }
        
        // Match [mm:ss.xx] or [mm:ss] format
        let regex = try! NSRegularExpression(pattern: "^\\[(\\d+):(\\d+)(?:\\.(\\d+))?\\](.*)$", options: [])
        
        let rawLines = lrcContent.components(separatedBy: .newlines)
        var entries: [LyricLine.RawEntry] = []
        
        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range) {
                let minStr = (trimmed as NSString).substring(with: match.range(at: 1))
                let secStr = (trimmed as NSString).substring(with: match.range(at: 2))
                let fraction: String? = match.range(at: 3).location != NSNotFound
                    ? (trimmed as NSString).substring(with: match.range(at: 3))
                    : nil
                let timestamp = LyricLine.parseTime(minutes: minStr, seconds: secStr, fraction: fraction)
                // Body mentah: tag word-level <mm:ss.xx> harus lolos ke makeLines.
                let body = (trimmed as NSString).substring(with: match.range(at: 4))
                entries.append(LyricLine.RawEntry(timestamp: timestamp, body: body))
            }
        }

        return LyricLine.makeLines(entries)
    }

    // MARK: - Romanization
    /// Converts Hangul / Hiragana / Katakana / Han to Latin script via the
    /// ICU transliterator built into CFStringTransform. Returns nil when the
    /// input already has no CJK characters or the transform produces no
    /// change (avoids storing redundant copies).
    static func romanize(_ text: String) -> String? {
        let needsTransform = text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0xAC00...0xD7AF).contains(v) ||  // Hangul Syllables
                   (0x1100...0x11FF).contains(v) ||  // Hangul Jamo
                   (0x3040...0x309F).contains(v) ||  // Hiragana
                   (0x30A0...0x30FF).contains(v) ||  // Katakana
                   (0x4E00...0x9FFF).contains(v) ||  // CJK Unified Ideographs
                   (0x3400...0x4DBF).contains(v)     // CJK Extension A
        }
        guard needsTransform else { return nil }

        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, "Any-Latin" as NSString, false) else { return nil }
        let out = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty || out == text ? nil : out
    }
    
    private func manualSelectionFile(for track: Track) -> URL {
        cacheDirectory.appendingPathComponent(
            "\(getCacheSlug(artist: track.artist, title: track.title)).manual.json"
        )
    }

    private func getCacheSlug(artist: String, title: String) -> String {
        let combined = "\(artist.lowercased())_\(title.lowercased())"
        let allowed = CharacterSet.alphanumerics
        return String(combined.unicodeScalars.filter { allowed.contains($0) || $0 == "_" })
    }
}

// MARK: - Decodable Helpers
struct LRCLIBResponse: Codable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatMessage
}

private struct OllamaChatMessage: Decodable {
    let content: String
}

private struct OllamaNormalizedTrack: Decodable {
    let track: String
    let artist: String
}

struct CachedLyricWord: Codable {
    let text: String
    let romanized: String?
    let start: TimeInterval
    let end: TimeInterval
    let joinsNext: Bool?  // optional — cache files written before this field still decode

    init(text: String, romanized: String?, start: TimeInterval, end: TimeInterval, joinsNext: Bool? = nil) {
        self.text = text
        self.romanized = romanized
        self.start = start
        self.end = end
        self.joinsNext = joinsNext
    }
}

struct CachedLyricLine: Codable {
    let timestamp: TimeInterval
    let text: String
    let romanized: String?
    let words: [CachedLyricWord]?  // nil untuk cache lama — tetap ter-decode

    init(timestamp: TimeInterval, text: String, romanized: String?, words: [CachedLyricWord]?) {
        self.timestamp = timestamp
        self.text = text
        self.romanized = romanized
        self.words = words
    }
}
