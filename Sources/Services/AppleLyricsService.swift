import Foundation

/// Real syllable-level timings from the Apple Music lyrics catalog via the
/// paxsenix community proxy (the only verified zero-auth route to Apple's
/// syllable data). LRCLIB remains the fallback for tracks Apple does not carry.
enum AppleLyricsService {
    struct Candidate: Equatable, Decodable {          // one iTunes search hit
        let trackId: Int
        let trackName: String
        let artistName: String
        let trackTimeMillis: Int?
    }

    enum AppleLyricsError: Error, Equatable {
        case notSyllableSynced
        case empty
        case badResponse
    }

    private static let userAgent = "PlayerStudio/1.0 (https://github.com/antikode/verse-bar)"
    private static let genericArtists: Set<String> = ["Unknown Artist", "YouTube Music", "YouTube"]

    // MARK: - Search term & candidate picking

    /// iTunes search term: drop bracketed noise and anything after a pipe.
    static func searchTerm(title: String, artist: String) -> String {
        var result = cleanTitle(title)
        if !genericArtists.contains(artist) {
            result += " " + artist
        }
        return result
    }

    private static func cleanTitle(_ title: String) -> String {
        var result = title.replacingOccurrences(
            of: "\\([^)]*\\)|\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        if let pipe = result.firstIndex(of: "|") {
            result = String(result[..<pipe])
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Deterministic pick, or nil when nothing matches well enough.
    static func pickCandidate(_ results: [Candidate], title: String, artist: String, duration: TimeInterval) -> Candidate? {
        let titleTokens = normalizedTokens(cleanTitle(title))
        let artistTokens = genericArtists.contains(artist) ? nil : normalizedTokens(artist)

        var survivors: [(candidate: Candidate, delta: Double)] = []
        for candidate in results {
            let nameTokens = normalizedTokens(candidate.trackName)
            guard !nameTokens.isDisjoint(with: titleTokens) else { continue }
            if let artistTokens, normalizedTokens(candidate.artistName).isDisjoint(with: artistTokens) {
                continue
            }
            survivors.append((candidate, abs((Double(candidate.trackTimeMillis ?? 0) / 1000) - duration)))
        }

        if duration > 0 {
            let matching = survivors.filter { $0.delta <= 4 }
            return matching.min { $0.delta < $1.delta }?.candidate
        }
        return survivors.first?.candidate
    }

    private static func normalizedTokens(_ text: String) -> Set<String> {
        let folded = text.precomposedStringWithCanonicalMapping.lowercased()
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
    }

    // MARK: - Parsing

    private struct Payload: Decodable { let syncType: String?; let lyrics: [Line]? }
    private struct Line: Decodable { let timestamp: Double; let endtime: Double?; let text: [Token]? }
    private struct Token: Decodable { let text: String; let timestamp: Double; let endtime: Double; let part: Bool? }

    private struct SearchResponse: Decodable { let results: [Candidate] }

    /// Paxsenix JSON -> lyric lines. Throws on non-syllable / empty payloads.
    static func parseSyllableLyrics(_ data: Data) throws -> [LyricLine] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AppleLyricsError.badResponse
        }
        guard payload.syncType == "Syllable" else {
            throw AppleLyricsError.notSyllableSynced
        }

        var lines: [LyricLine] = []
        for line in payload.lyrics ?? [] {
            guard let tokens = line.text, !tokens.isEmpty else { continue }

            var words: [LyricWord] = []
            var lineText = ""
            for (index, token) in tokens.enumerated() {
                if index > 0 && !(tokens[index - 1].part ?? false) {
                    lineText += " "
                }
                lineText += token.text
                let start = token.timestamp / 1000
                let end = max(token.endtime / 1000, start)
                words.append(LyricWord(
                    text: token.text,
                    romanized: LyricsService.romanize(token.text),
                    start: start,
                    end: end,
                    joinsNext: token.part ?? false
                ))
            }
            lineText = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(LyricLine(
                timestamp: line.timestamp / 1000,
                text: lineText,
                romanized: LyricsService.romanize(lineText),
                words: words
            ))
        }

        guard !lines.isEmpty else { throw AppleLyricsError.empty }
        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Fetch

    /// Full two-hop lookup on a background queue; completion on the main queue.
    static func fetch(title: String, artist: String, duration: TimeInterval,
                      completion: @escaping ([LyricLine]?) -> Void) {
        let searchTerm = searchTerm(title: title, artist: artist)
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: searchTerm),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let searchURL = components.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        Logger.info("🌐 Fetching Apple Music lyrics for \(title) — \(artist)", category: "lyrics")
        var request = URLRequest(url: searchURL, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let miss = { (reason: String) in
                Logger.info("⚠️ Apple Music lyrics miss for \(title): \(reason)", category: "lyrics")
                DispatchQueue.main.async { completion(nil) }
            }
            guard error == nil, let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                miss("iTunes search failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return
            }
            let results: [Candidate]
            do {
                results = try JSONDecoder().decode(SearchResponse.self, from: data).results
            } catch {
                miss("iTunes search decode failed")
                return
            }
            guard let candidate = pickCandidate(results, title: title, artist: artist, duration: duration) else {
                miss("no matching candidate")
                return
            }

            let lyricsURL = URL(string: "https://lyrics.paxsenix.org/apple-music/lyrics?id=\(candidate.trackId)&v=2")!
            var lyricsRequest = URLRequest(url: lyricsURL, timeoutInterval: 8)
            lyricsRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: lyricsRequest) { data, response, error in
                guard error == nil, let data,
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    // A miss is a 500, not a 404 — treat any non-200 as a miss.
                    miss("lyrics fetch failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    return
                }
                do {
                    let lines = try parseSyllableLyrics(data)
                    Logger.info("✅ Apple Music syllable lyrics for \(title) (\(lines.count) lines)", category: "lyrics")
                    DispatchQueue.main.async { completion(lines) }
                } catch {
                    miss("\(error)")
                }
            }.resume()
        }.resume()
    }
}
