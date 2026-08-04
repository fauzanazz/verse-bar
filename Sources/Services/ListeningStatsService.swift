import Combine
import Foundation
import SQLite3

enum CoverFilter {
    case all
    case original
    case cover
}

struct SongStat: Identifiable {
    let id: String
    let title: String
    let artist: String
    let videoID: String?
    let plays: Int
}

struct ArtistStat: Identifiable {
    var id: String { artist }
    let artist: String
    let plays: Int
}

struct ListeningCapsule {
    let totalPlays: Int
    let topSongs: [SongStat]
    let topArtists: [ArtistStat]
}

private let emptyListeningCapsule = ListeningCapsule(totalPlays: 0, topSongs: [], topArtists: [])

final class ListeningStatsService {
    static let shared = ListeningStatsService()

    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "com.playerstudio.stats")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var cancellables = Set<AnyCancellable>()

    private var activeKey: String?
    private var countedThisSession = false
    private var lastProgress: TimeInterval = 0

    private init() {
        let appSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.playerstudio.PlayerStudio", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: appSupportDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            Logger.error("Failed to create listening stats directory", category: "stats", error: error)
        }

        let databaseURL = appSupportDirectory.appendingPathComponent("ListeningStats.sqlite3")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            Logger.error("Failed to open listening stats database", category: "stats", error: StatsError.sqlite)
            if database != nil { sqlite3_close(database) }
            database = nil
            return
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS plays (
            id INTEGER PRIMARY KEY,
            played_at INTEGER NOT NULL,
            song_key TEXT NOT NULL,
            video_id TEXT,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            is_cover INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_plays_played_at ON plays(played_at);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            Logger.error("Failed to initialize listening stats database", category: "stats", error: StatsError.sqlite)
            sqlite3_close(database)
            database = nil
            return
        }

        PlaybackEngine.shared.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.handle(track)
            }
            .store(in: &cancellables)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    private func handle(_ track: Track?) {
        guard let track else { return }

        let key = identityKey(track)
        let progress = track.currentProgress
        if key != activeKey {
            activeKey = key
            countedThisSession = false
        } else if progress + 5 < lastProgress {
            countedThisSession = false
        }
        lastProgress = progress

        // ponytail: Seeking past the threshold counts; a loop reset hidden by the
        // 5-second jitter tolerance can under-count. Track listened time if that matters.
        let threshold = min(30, max(1, track.duration * 0.5))
        guard !countedThisSession, progress >= threshold else { return }
        countedThisSession = true
        record(track)
    }

    private func identityKey(_ track: Track) -> String {
        if let videoID = Self.videoID(fromArtworkURL: track.artworkURL) {
            return "yt:\(videoID)"
        }
        return "ta:" + Track.makeSyncOffsetKey(title: track.title, artist: track.artist)
    }

    static func videoID(fromArtworkURL url: URL?) -> String? {
        guard let components = url?.pathComponents,
              let marker = components.firstIndex(of: "vi"),
              marker + 1 < components.endIndex else { return nil }
        let videoID = components[marker + 1]
        guard videoID.count == 11,
              videoID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              }) else { return nil }
        return videoID
    }

    static func isCover(title: String) -> Bool {
        title.range(of: "\\bcover\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    func capsule(monthStart: Date, filter: CoverFilter) -> ListeningCapsule {
        queue.sync {
            guard let database,
                  let interval = Calendar.current.dateInterval(of: .month, for: monthStart) else {
                return emptyListeningCapsule
            }

            let start = Int64(interval.start.timeIntervalSince1970)
            let end = Int64(interval.end.timeIntervalSince1970)
            let coverPredicate: String
            switch filter {
            case .all:
                coverPredicate = ""
            case .original:
                coverPredicate = " AND is_cover = 0"
            case .cover:
                coverPredicate = " AND is_cover = 1"
            }

            let totalSQL = """
            SELECT COUNT(*) FROM plays
            WHERE played_at >= ? AND played_at < ?\(coverPredicate)
            """
            var statement: OpaquePointer?
            var totalPlays = 0
            if sqlite3_prepare_v2(database, totalSQL, -1, &statement, nil) == SQLITE_OK {
                bindRange(statement, start: start, end: end)
                if sqlite3_step(statement) == SQLITE_ROW {
                    totalPlays = Int(sqlite3_column_int64(statement, 0))
                }
            }
            sqlite3_finalize(statement)

            let songsSQL = """
            SELECT song_key, title, artist, video_id, COUNT(*) c FROM plays
            WHERE played_at >= ? AND played_at < ?\(coverPredicate)
            GROUP BY song_key
            ORDER BY c DESC, MAX(played_at) DESC
            LIMIT 5
            """
            statement = nil
            var topSongs: [SongStat] = []
            if sqlite3_prepare_v2(database, songsSQL, -1, &statement, nil) == SQLITE_OK {
                bindRange(statement, start: start, end: end)
                while sqlite3_step(statement) == SQLITE_ROW,
                      let key = columnText(statement, index: 0),
                      let title = columnText(statement, index: 1),
                      let artist = columnText(statement, index: 2) {
                    let videoID = sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil
                        : columnText(statement, index: 3)
                    topSongs.append(SongStat(
                        id: key,
                        title: title,
                        artist: artist,
                        videoID: videoID,
                        plays: Int(sqlite3_column_int64(statement, 4))
                    ))
                }
            }
            sqlite3_finalize(statement)

            let artistsSQL = """
            SELECT artist, COUNT(*) c FROM plays
            WHERE played_at >= ? AND played_at < ?\(coverPredicate)
            GROUP BY artist
            ORDER BY c DESC, MAX(played_at) DESC
            LIMIT 5
            """
            statement = nil
            var topArtists: [ArtistStat] = []
            if sqlite3_prepare_v2(database, artistsSQL, -1, &statement, nil) == SQLITE_OK {
                bindRange(statement, start: start, end: end)
                while sqlite3_step(statement) == SQLITE_ROW,
                      let artist = columnText(statement, index: 0) {
                    topArtists.append(ArtistStat(
                        artist: artist,
                        plays: Int(sqlite3_column_int64(statement, 1))
                    ))
                }
            }
            sqlite3_finalize(statement)

            return ListeningCapsule(
                totalPlays: totalPlays,
                topSongs: topSongs,
                topArtists: topArtists
            )
        }
    }

    /// Most recent distinct songs, newest first.
    func recentPlays(limit: Int) -> [(songKey: String, title: String, artist: String, playedAt: Date)] {
        queue.sync {
            guard let database else { return [] }
            let sql = """
            SELECT song_key, title, artist, MAX(played_at) p FROM plays
            GROUP BY song_key ORDER BY p DESC LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var results: [(songKey: String, title: String, artist: String, playedAt: Date)] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let key = columnText(statement, index: 0),
                  let title = columnText(statement, index: 1),
                  let artist = columnText(statement, index: 2) {
                let playedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)))
                results.append((key, title, artist, playedAt))
            }
            return results
        }
    }

    /// song_key → last play time, for the "Last Played" sort.
    func lastPlayedByKey() -> [String: Date] {
        queue.sync {
            guard let database else { return [:] }
            let sql = "SELECT song_key, MAX(played_at) FROM plays GROUP BY song_key"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(statement) }

            var byKey: [String: Date] = [:]
            while sqlite3_step(statement) == SQLITE_ROW,
                  let key = columnText(statement, index: 0) {
                byKey[key] = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
            }
            return byKey
        }
    }

    private func bindRange(_ statement: OpaquePointer?, start: Int64, end: Int64) {
        sqlite3_bind_int64(statement, 1, start)
        sqlite3_bind_int64(statement, 2, end)
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func record(_ track: Track) {
        let key = identityKey(track)
        let videoID = Self.videoID(fromArtworkURL: track.artworkURL)
        let isCover = Self.isCover(title: track.title)

        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let sql = """
            INSERT INTO plays (played_at, song_key, video_id, title, artist, is_cover)
            VALUES (strftime('%s','now'), ?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, self.transient)
            if let videoID {
                sqlite3_bind_text(statement, 2, videoID, -1, self.transient)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, track.title, -1, self.transient)
            sqlite3_bind_text(statement, 4, track.artist, -1, self.transient)
            sqlite3_bind_int(statement, 5, isCover ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Logger.error("Failed to record listening stat", category: "stats", error: StatsError.sqlite)
                return
            }
            Logger.debug("Recorded play: \(track.artist) — \(track.title)", category: "stats")
        }
    }

    private enum StatsError: Error {
        case sqlite
    }
}
