import Combine
import Foundation
import SQLite3

enum CoverFilter {
    case all
    case original
    case cover
}

final class ListeningStatsService {
    static let shared = ListeningStatsService()

    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "com.playerstudio.stats")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var cancellables = Set<AnyCancellable>()

    private var activeKey: String?
    private var countedThisSession = false
    private var lastProgress: TimeInterval = 0
    private var activeRowID: Int64?
    private var pendingSeconds: Double = 0

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

        // One-column migration, idempotent by ignoring the duplicate-column
        // error — that error is the expected steady state on every launch.
        sqlite3_exec(database, "ALTER TABLE plays ADD COLUMN seconds INTEGER NOT NULL DEFAULT 0", nil, nil, nil)

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
        guard let track, PlaybackEngine.shared.isSourceActive else { return }

        let key = identityKey(track)
        let progress = track.currentProgress
        if key != activeKey {
            // Track change: bank any buffered seconds on the old row, then reset.
            flushPending()
            activeKey = key
            countedThisSession = false
            activeRowID = nil
            lastProgress = progress
            return
        }
        if progress + 5 < lastProgress {
            // Loop reset or seek-back.
            flushPending()
            countedThisSession = false
            activeRowID = nil
            lastProgress = progress
            return
        }

        let delta = progress - lastProgress
        if delta > 0 && delta <= 10 {
            pendingSeconds += delta
        }
        lastProgress = progress

        // ponytail: Seconds listened before the play threshold trips are included
        // (they sit in pendingSeconds and land on the row at insert time), but a
        // track abandoned before the threshold records nothing at all. Seeking past
        // the threshold counts; a loop reset hidden by the 5-second jitter
        // tolerance can under-count.
        let threshold = min(30, max(1, track.duration * 0.5))
        if !countedThisSession, progress >= threshold {
            countedThisSession = true
            record(track)
        }
        if pendingSeconds >= 15 {
            flushPending()
        }
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

    private func coverPredicate(_ filter: CoverFilter) -> String {
        switch filter {
        case .all: return ""
        case .original: return " AND is_cover = 0"
        case .cover: return " AND is_cover = 1"
        }
    }

    /// Every play in the interval, oldest first.
    func plays(in interval: DateInterval, filter: CoverFilter) -> [PlayRecord] {
        queue.sync {
            guard let database else { return [] }
            let sql = """
            SELECT played_at, song_key, video_id, title, artist, is_cover, seconds FROM plays
            WHERE played_at >= ? AND played_at < ?\(coverPredicate(filter))
            ORDER BY played_at ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bindRange(statement, start: Int64(interval.start.timeIntervalSince1970), end: Int64(interval.end.timeIntervalSince1970))

            var records: [PlayRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let key = columnText(statement, index: 1),
                  let title = columnText(statement, index: 3),
                  let artist = columnText(statement, index: 4) {
                let videoID = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : columnText(statement, index: 2)
                records.append(PlayRecord(
                    playedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    songKey: key,
                    videoID: videoID,
                    title: title,
                    artist: artist,
                    isCover: sqlite3_column_int(statement, 5) != 0,
                    seconds: Int(sqlite3_column_int64(statement, 6))
                ))
            }
            return records
        }
    }

    /// Lifetime aggregates for everything played strictly before `end`.
    func lifetimeTotals(before end: Date, filter: CoverFilter) -> LifetimeTotals {
        queue.sync {
            guard let database else {
                return LifetimeTotals(seconds: 0, plays: 0, playsBySong: [:], playsByArtist: [:], titleBySong: [:])
            }
            let sql = """
            SELECT song_key, title, artist, COUNT(*) c, SUM(seconds) s, MAX(played_at) m FROM plays
            WHERE played_at < ?\(coverPredicate(filter))
            GROUP BY song_key
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                return LifetimeTotals(seconds: 0, plays: 0, playsBySong: [:], playsByArtist: [:], titleBySong: [:])
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(end.timeIntervalSince1970))

            var seconds = 0
            var plays = 0
            var playsBySong: [String: Int] = [:]
            var playsByArtist: [String: Int] = [:]
            var titleBySong: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW,
                  let key = columnText(statement, index: 0),
                  let title = columnText(statement, index: 1),
                  let artist = columnText(statement, index: 2) {
                let groupPlays = Int(sqlite3_column_int64(statement, 3))
                plays += groupPlays
                seconds += Int(sqlite3_column_int64(statement, 4))
                playsBySong[key] = groupPlays
                playsByArtist[artist, default: 0] += groupPlays
                titleBySong[key] = title
            }
            return LifetimeTotals(
                seconds: seconds,
                plays: plays,
                playsBySong: playsBySong,
                playsByArtist: playsByArtist,
                titleBySong: titleBySong
            )
        }
    }

    /// songKey → first-ever play time, for the discoveries card.
    func firstPlayByKey(filter: CoverFilter) -> [String: Date] {
        queue.sync {
            guard let database else { return [:] }
            let sql = "SELECT song_key, MIN(played_at) FROM plays WHERE 1=1\(coverPredicate(filter)) GROUP BY song_key"
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

    /// Distinct month starts that have at least one play, newest first.
    func monthsWithPlays() -> [Date] {
        queue.sync {
            guard let database else { return [] }
            let sql = "SELECT DISTINCT strftime('%Y-%m-01', played_at, 'unixepoch', 'localtime') FROM plays ORDER BY 1 DESC"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            var months: [Date] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let text = columnText(statement, index: 0),
                  let date = formatter.date(from: text) {
                months.append(date)
            }
            return months
        }
    }

    /// Orchestrates the fetches above and hands off to ListeningCapsule.build.
    /// Runs on the caller's thread; the fetch helpers synchronize internally.
    func capsule(monthStart: Date, filter: CoverFilter) -> ListeningCapsule {
        guard let interval = Calendar.current.dateInterval(of: .month, for: monthStart),
              let previousInterval = Calendar.current.dateInterval(
                  of: .month,
                  for: interval.start.addingTimeInterval(-1)
              ) else { return .empty }
        return ListeningCapsule.build(
            monthStart: interval.start,
            records: plays(in: interval, filter: filter),
            previous: plays(in: previousInterval, filter: filter),
            lifetimeAtMonthEnd: lifetimeTotals(before: interval.end, filter: filter),
            firstPlayByKey: firstPlayByKey(filter: filter),
            now: Date(),
            calendar: Calendar.current
        )
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

    /// Writes buffered listened seconds onto the current play row.
    private func flushPending() {
        let seconds = Int(pendingSeconds)
        guard seconds > 0, let rowID = activeRowID else { return }
        pendingSeconds -= Double(seconds)
        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let sql = "UPDATE plays SET seconds = seconds + ? WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(seconds))
            sqlite3_bind_int64(statement, 2, rowID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Logger.error("Failed to flush listened seconds", category: "stats", error: StatsError.sqlite)
                return
            }
            Logger.debug("Flushed \(seconds)s listened time", category: "stats")
        }
    }

    /// Public flush for app termination.
    func flush() {
        flushPending()
        queue.sync {}
    }

    private func record(_ track: Track) {
        let key = identityKey(track)
        let videoID = Self.videoID(fromArtworkURL: track.artworkURL)
        let isCover = Self.isCover(title: track.title)
        let seconds = Int(pendingSeconds)
        pendingSeconds -= Double(seconds)

        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let sql = """
            INSERT INTO plays (played_at, song_key, video_id, title, artist, is_cover, seconds)
            VALUES (strftime('%s','now'), ?, ?, ?, ?, ?, ?)
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
            sqlite3_bind_int(statement, 6, Int32(seconds))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Logger.error("Failed to record listening stat", category: "stats", error: StatsError.sqlite)
                return
            }
            let rowID = sqlite3_last_insert_rowid(database)
            DispatchQueue.main.async { [weak self] in
                self?.activeRowID = rowID
            }
            Logger.debug("Recorded play: \(track.artist) — \(track.title)", category: "stats")
        }
    }

    private enum StatsError: Error {
        case sqlite
    }
}
