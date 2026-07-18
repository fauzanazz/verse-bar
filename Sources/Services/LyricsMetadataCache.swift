import Foundation
import SQLite3

struct CachedMetadataQuery {
    let query: String
    let isFuzzyMatch: Bool
}

final class LyricsMetadataCache {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL) {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            Logger.error("Failed to open lyrics metadata cache", category: "lyrics", error: CacheError.sqlite)
            if database != nil { sqlite3_close(database) }
            database = nil
            return
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS metadata_cache (
            id INTEGER PRIMARY KEY,
            source_title TEXT NOT NULL COLLATE NOCASE,
            source_artist TEXT NOT NULL COLLATE NOCASE,
            normalized_track TEXT NOT NULL,
            normalized_artist TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(source_title, source_artist)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS metadata_cache_fts USING fts5(
            source_title,
            source_artist,
            content='metadata_cache',
            content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS metadata_cache_ai AFTER INSERT ON metadata_cache BEGIN
            INSERT INTO metadata_cache_fts(rowid, source_title, source_artist)
            VALUES (new.id, new.source_title, new.source_artist);
        END;
        CREATE TRIGGER IF NOT EXISTS metadata_cache_ad AFTER DELETE ON metadata_cache BEGIN
            INSERT INTO metadata_cache_fts(metadata_cache_fts, rowid, source_title, source_artist)
            VALUES ('delete', old.id, old.source_title, old.source_artist);
        END;
        CREATE TRIGGER IF NOT EXISTS metadata_cache_au AFTER UPDATE ON metadata_cache BEGIN
            INSERT INTO metadata_cache_fts(metadata_cache_fts, rowid, source_title, source_artist)
            VALUES ('delete', old.id, old.source_title, old.source_artist);
            INSERT INTO metadata_cache_fts(rowid, source_title, source_artist)
            VALUES (new.id, new.source_title, new.source_artist);
        END;
        """

        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            Logger.error("Failed to initialize lyrics metadata cache", category: "lyrics", error: CacheError.sqlite)
            sqlite3_close(database)
            database = nil
            return
        }
        sqlite3_exec(database, "INSERT INTO metadata_cache_fts(metadata_cache_fts) VALUES('rebuild')", nil, nil, nil)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func lookup(title: String, artist: String) -> CachedMetadataQuery? {
        guard let database else { return nil }

        let exactSQL = """
        SELECT normalized_track, normalized_artist
        FROM metadata_cache
        WHERE source_title = ? COLLATE NOCASE AND source_artist = ? COLLATE NOCASE
        LIMIT 1
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, exactSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, title, -1, transient)
            sqlite3_bind_text(statement, 2, artist, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW,
               let track = columnText(statement, index: 0),
               let normalizedArtist = columnText(statement, index: 1) {
                sqlite3_finalize(statement)
                return CachedMetadataQuery(query: "\(normalizedArtist) \(track)", isFuzzyMatch: false)
            }
        }
        sqlite3_finalize(statement)

        let titleTokens = meaningfulTokens(title)
        guard !titleTokens.isEmpty else { return nil }
        let match = "source_title : (" + titleTokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ") + ")"
        let fuzzySQL = """
        SELECT metadata_cache.source_title, metadata_cache.normalized_track, metadata_cache.normalized_artist
        FROM metadata_cache_fts
        JOIN metadata_cache ON metadata_cache.id = metadata_cache_fts.rowid
        WHERE metadata_cache_fts MATCH ?
        ORDER BY metadata_cache.updated_at DESC
        LIMIT 20
        """

        statement = nil
        guard sqlite3_prepare_v2(database, fuzzySQL, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, transient)

        var best: (score: Double, query: String)?
        while sqlite3_step(statement) == SQLITE_ROW,
              let sourceTitle = columnText(statement, index: 0),
              let track = columnText(statement, index: 1),
              let normalizedArtist = columnText(statement, index: 2) {
            let candidateTokens = meaningfulTokens(sourceTitle)
            let intersection = titleTokens.intersection(candidateTokens).count
            let denominator = min(titleTokens.count, candidateTokens.count)
            guard denominator > 0 else { continue }
            let score = Double(intersection) / Double(denominator)
            if score > (best?.score ?? 0) {
                best = (score, "\(normalizedArtist) \(track)")
            }
        }

        guard let best, best.score >= 0.75 else { return nil }
        return CachedMetadataQuery(query: best.query, isFuzzyMatch: true)
    }

    func store(sourceTitle: String, sourceArtist: String, normalizedTrack: String, normalizedArtist: String) {
        guard let database else { return }
        let sql = """
        INSERT INTO metadata_cache (source_title, source_artist, normalized_track, normalized_artist, updated_at)
        VALUES (?, ?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(source_title, source_artist) DO UPDATE SET
            normalized_track = excluded.normalized_track,
            normalized_artist = excluded.normalized_artist,
            updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sourceTitle, -1, transient)
        sqlite3_bind_text(statement, 2, sourceArtist, -1, transient)
        sqlite3_bind_text(statement, 3, normalizedTrack, -1, transient)
        sqlite3_bind_text(statement, 4, normalizedArtist, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            Logger.error("Failed to save lyrics metadata cache", category: "lyrics", error: CacheError.sqlite)
            return
        }
        Logger.info("Saved normalized metadata to persistent cache: \(normalizedArtist) \(normalizedTrack)", category: "lyrics")
    }

    private func meaningfulTokens(_ value: String) -> Set<String> {
        let ignored = Set(["cover", "acoustic", "karaoke", "live", "official", "video", "lyric", "lyrics", "feat", "ft"])
        return Set(value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !ignored.contains($0) })
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private enum CacheError: Error {
        case sqlite
    }
}
