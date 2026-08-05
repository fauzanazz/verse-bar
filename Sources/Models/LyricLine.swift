import Foundation

struct LyricWord: Equatable {
    let text: String
    let romanized: String?
    let start: TimeInterval
    let end: TimeInterval
    /// True when the next word attaches with no space (Apple syllable `part`).
    let joinsNext: Bool

    init(text: String, romanized: String?, start: TimeInterval, end: TimeInterval, joinsNext: Bool = false) {
        self.text = text
        self.romanized = romanized
        self.start = start
        self.end = end
        self.joinsNext = joinsNext
    }
}

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp: TimeInterval // Elapsed time in seconds from start of song
    let text: String
    let romanized: String?
    let words: [LyricWord]

    init(timestamp: TimeInterval, text: String, romanized: String? = nil, words: [LyricWord] = []) {
        self.timestamp = timestamp
        self.text = text
        self.romanized = romanized
        self.words = words
    }

    /// Parses "mm:ss", "mm:ss.xx", "mm:ss.xxx", "mm:ss:xx" → seconds.
    static func parseTime(minutes: String, seconds: String, fraction: String?) -> TimeInterval {
        let fractional: TimeInterval
        if let fraction {
            if fraction.count == 2 {
                fractional = (Double(fraction) ?? 0.0) / 100.0
            } else if fraction.count == 3 {
                fractional = (Double(fraction) ?? 0.0) / 1000.0
            } else {
                fractional = (Double(fraction) ?? 0.0) / pow(10.0, Double(fraction.count))
            }
        } else {
            fractional = 0.0
        }
        return (Double(minutes) ?? 0.0) * 60.0 + (Double(seconds) ?? 0.0) + fractional
    }

    // ponytail: laju vokal tetap 0.13 s per unit karakter — pas untuk pop
    // (baris 25 karakter ≈ 3.3 s). Kalau ada lagu yang jelas meleset, kalibrasi
    // per-lagu dari jarak antar baris ber-timestamp, bukan tambah konstanta baru.
    static let secondsPerCharacterUnit: TimeInterval = 0.13

    /// Aksara silabis (Hangul, Kana, Han) = 1 glyph 1 suku kata → bobot 2,
    /// sisanya 1. Whitespace tidak dihitung.
    static func characterWeight(_ character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if character.isWhitespace { return 0 }
        let v = scalar.value
        if (0xAC00...0xD7AF).contains(v) ||  // Hangul Syllables
            (0x1100...0x11FF).contains(v) ||  // Hangul Jamo
            (0x3040...0x309F).contains(v) ||  // Hiragana
            (0x30A0...0x30FF).contains(v) ||  // Katakana
            (0x4E00...0x9FFF).contains(v) ||  // CJK Unified Ideographs
            (0x3400...0x4DBF).contains(v) {   // CJK Extension A
            return 2
        }
        return 1
    }

    /// Bobot token = Σ characterWeight + 1 (mewakili jeda antar kata).
    static func tokenWeight(_ token: String) -> Double {
        token.reduce(0.0) { $0 + characterWeight($1) } + 1
    }

    /// max(0.6, Σ tokenWeight × secondsPerCharacterUnit); 0 untuk teks kosong.
    static func estimatedSingingDuration(_ text: String) -> TimeInterval {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let total = tokens.reduce(0.0) { $0 + tokenWeight($1) }
        return max(0.6, total * secondsPerCharacterUnit)
    }

    static func stripInlineWordTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<\\d+:\\d+(?:[.:]\\d+)?>",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeWords(text: String, start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        // ponytail: floor 0 bukan 0.2 — segmen word-tag bisa < 0.2 s dan harus
        // berakhir persis di tag berikutnya; makeLines menjamin end >= start.
        let duration = max(end - start, 0)
        let weights = tokens.map(tokenWeight)
        let totalWeight = weights.reduce(0, +)
        var cursor = start

        return zip(tokens, weights).map { token, weight in
            let wordEnd = cursor + duration * weight / totalWeight
            defer { cursor = wordEnd }
            return LyricWord(
                text: token,
                romanized: LyricsService.romanize(token),
                start: cursor,
                end: wordEnd
            )
        }
    }

    /// Segmen A2: teks setelah sebuah tag <mm:ss.xx> (atau teks sebelum tag
    /// pertama, yang memakai timestamp baris). Kembalikan [] kalau baris tidak
    /// punya tag sama sekali.
    static func inlineTimedSegments(_ body: String, lineStart: TimeInterval) -> [(text: String, start: TimeInterval)] {
        let regex = try! NSRegularExpression(pattern: "<(\\d+):(\\d+)(?:[.:](\\d+))?>", options: [])
        let nsBody = body as NSString
        let matches = regex.matches(in: body, options: [], range: NSRange(location: 0, length: nsBody.length))
        guard !matches.isEmpty else { return [] }

        var segments: [(text: String, start: TimeInterval)] = []

        let before = nsBody.substring(with: NSRange(location: 0, length: matches[0].range.location))
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append((before, lineStart))
        }

        for (i, match) in matches.enumerated() {
            let minutes = nsBody.substring(with: match.range(at: 1))
            let seconds = nsBody.substring(with: match.range(at: 2))
            let fraction: String? = match.range(at: 3).location != NSNotFound
                ? nsBody.substring(with: match.range(at: 3))
                : nil
            let start = parseTime(minutes: minutes, seconds: seconds, fraction: fraction)

            let textStart = match.range.location + match.range.length
            let textEnd = i + 1 < matches.count ? matches[i + 1].range.location : nsBody.length
            let text = nsBody.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append((text, start))
            }
        }

        // Buang segmen dengan start mundur (tag rusak/urutan terbalik) supaya
        // word timing tidak pernah bergerak mundur.
        var filtered: [(text: String, start: TimeInterval)] = []
        for segment in segments {
            if let last = filtered.last, segment.start < last.start { continue }
            filtered.append(segment)
        }
        return filtered
    }

    struct RawEntry {
        let timestamp: TimeInterval
        let body: String        // boleh mengandung tag <mm:ss.xx>
        let romanized: String?  // nil → hitung dari teks yang sudah di-strip

        init(timestamp: TimeInterval, body: String, romanized: String? = nil) {
            self.timestamp = timestamp
            self.body = body
            self.romanized = romanized
        }
    }

    static func makeLines(_ entries: [RawEntry]) -> [LyricLine] {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        return sorted.enumerated().map { index, entry in
            let text = stripInlineWordTags(entry.body)
            let romanized = entry.romanized ?? LyricsService.romanize(text)
            let nextTimestamp = sorted.indices.contains(index + 1) ? sorted[index + 1].timestamp : nil
            // Pembatas durasi nyanyi: jangan pernah menyeret fill ke timestamp
            // baris berikutnya (jeda instrumental panjang) atau melewati
            // perkiraan lama baris ini.
            let lineEnd = min(nextTimestamp ?? .greatestFiniteMagnitude, entry.timestamp + estimatedSingingDuration(text))

            let segments = inlineTimedSegments(entry.body, lineStart: entry.timestamp)
            let words: [LyricWord]
            if segments.isEmpty {
                words = makeWords(text: text, start: entry.timestamp, end: lineEnd)
            } else {
                var all: [LyricWord] = []
                for (i, segment) in segments.enumerated() {
                    let segmentEnd: TimeInterval
                    if i + 1 < segments.count {
                        segmentEnd = segments[i + 1].start
                    } else {
                        segmentEnd = min(
                            nextTimestamp ?? .greatestFiniteMagnitude,
                            segment.start + estimatedSingingDuration(segment.text)
                        )
                    }
                    all.append(contentsOf: makeWords(text: segment.text, start: segment.start, end: segmentEnd))
                }
                words = all
            }

            return LyricLine(timestamp: entry.timestamp, text: text, romanized: romanized, words: words)
        }
    }
}
