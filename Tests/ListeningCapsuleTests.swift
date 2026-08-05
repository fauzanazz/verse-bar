import XCTest
@testable import PlayerStudio

final class ListeningCapsuleTests: XCTestCase {
    /// Fixed UTC calendar so day/hour bucketing is deterministic.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// March 2026 — 31 days, no DST shift in UTC.
    private var monthStart: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
    }

    private func record(
        month: Int = 3,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        key: String,
        title: String,
        artist: String,
        seconds: Int,
        videoID: String? = nil
    ) -> PlayRecord {
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        return PlayRecord(
            playedAt: date,
            songKey: key,
            videoID: videoID,
            title: title,
            artist: artist,
            isCover: false,
            seconds: seconds
        )
    }

    private func build(
        records: [PlayRecord],
        previous: [PlayRecord] = [],
        lifetime: LifetimeTotals? = nil,
        firstPlayByKey: [String: Date] = [:],
        now: Date? = nil
    ) -> ListeningCapsule {
        ListeningCapsule.build(
            monthStart: monthStart,
            records: records,
            previous: previous,
            lifetimeAtMonthEnd: lifetime
                ?? LifetimeTotals(seconds: 0, plays: 0, playsBySong: [:], playsByArtist: [:], titleBySong: [:]),
            firstPlayByKey: firstPlayByKey,
            now: now ?? calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!,
            calendar: calendar
        )
    }

    // MARK: - Totals and ranking

    func testTotalsAndSongRanking() {
        let records = [
            record(day: 2, key: "a", title: "A", artist: "Artist A", seconds: 5),
            record(day: 3, key: "a", title: "A", artist: "Artist A", seconds: 10),
            record(day: 4, key: "b", title: "B", artist: "Artist B", seconds: 7),
        ]
        let capsule = build(records: records)

        XCTAssertEqual(capsule.totalPlays, 3)
        XCTAssertEqual(capsule.totalSeconds, 22)
        XCTAssertEqual(capsule.distinctSongs, 2)
        XCTAssertEqual(capsule.topSongs[0].plays, 2)
        XCTAssertEqual(capsule.topSongs[0].title, "A")
        XCTAssertEqual(capsule.topSongs[0].seconds, 15)
        XCTAssertEqual(capsule.topSongs[1].plays, 1)
    }

    func testDayPartsSplitByHeaviest() {
        let records = [
            record(day: 2, hour: 7, key: "a", title: "A", artist: "Artist A", seconds: 100),
            record(day: 3, hour: 23, key: "b", title: "B", artist: "Artist B", seconds: 200),
        ]
        let capsule = build(records: records)

        XCTAssertEqual(capsule.peakPart, .night)
        XCTAssertEqual(capsule.secondsByPart[.morning], 100)
        XCTAssertEqual(capsule.secondsByPart[.night], 200)
        XCTAssertEqual(capsule.playsByPart[.morning], 1)
        XCTAssertEqual(capsule.playsByPart[.night], 1)
    }

    func testActiveDaysAndStreak() {
        let records = [
            record(day: 1, key: "a", title: "A", artist: "Artist A", seconds: 10),
            record(day: 2, key: "b", title: "B", artist: "Artist B", seconds: 10),
            record(day: 3, key: "c", title: "C", artist: "Artist C", seconds: 10),
            record(day: 10, key: "d", title: "D", artist: "Artist D", seconds: 10),
        ]
        let capsule = build(records: records)

        XCTAssertEqual(capsule.activeDays, 4)
        XCTAssertEqual(capsule.longestStreakDays, 3)
        XCTAssertEqual(capsule.secondsByDay[0], 10)
        XCTAssertEqual(capsule.secondsByDay[1], 10)
        XCTAssertEqual(capsule.secondsByDay[2], 10)
        XCTAssertEqual(capsule.secondsByDay[3], 0)
        XCTAssertEqual(capsule.secondsByDay.count, 31)
    }

    // MARK: - Month-over-month

    func testPlaysChangeDelta() {
        let current = (1...12).map { record(day: $0, key: "s\($0)", title: "S\($0)", artist: "A\($0)", seconds: 30) }
        let previous = (1...10).map { record(month: 2, day: $0, key: "p\($0)", title: "P\($0)", artist: "A\($0)", seconds: 30) }

        let withPrevious = build(records: current, previous: previous)
        XCTAssertEqual(withPrevious.playsChange ?? -1, 0.2, accuracy: 0.0001)

        let noPrevious = build(records: current)
        XCTAssertNil(noPrevious.playsChange)
    }

    func testRankMovement() {
        // Previous month: A 5, B 3, Z 2 → Z is #3.
        let previous = [
            record(month: 2, day: 1, key: "a", title: "A", artist: "X", seconds: 30),
            record(month: 2, day: 2, key: "a", title: "A", artist: "X", seconds: 30),
            record(month: 2, day: 3, key: "a", title: "A", artist: "X", seconds: 30),
            record(month: 2, day: 4, key: "a", title: "A", artist: "X", seconds: 30),
            record(month: 2, day: 5, key: "a", title: "A", artist: "X", seconds: 30),
            record(month: 2, day: 1, key: "b", title: "B", artist: "Y", seconds: 30),
            record(month: 2, day: 2, key: "b", title: "B", artist: "Y", seconds: 30),
            record(month: 2, day: 3, key: "b", title: "B", artist: "Y", seconds: 30),
            record(month: 2, day: 1, key: "z", title: "Z", artist: "Zed", seconds: 30),
            record(month: 2, day: 2, key: "z", title: "Z", artist: "Zed", seconds: 30),
        ]
        // Current month: Z 5, X 3, Y 2 → Z is #1, up from #3.
        let current = [
            record(day: 1, key: "z", title: "Z", artist: "Zed", seconds: 30),
            record(day: 2, key: "z", title: "Z", artist: "Zed", seconds: 30),
            record(day: 3, key: "z", title: "Z", artist: "Zed", seconds: 30),
            record(day: 4, key: "z", title: "Z", artist: "Zed", seconds: 30),
            record(day: 5, key: "z", title: "Z", artist: "Zed", seconds: 30),
            record(day: 1, key: "x", title: "X", artist: "Ex", seconds: 30),
            record(day: 2, key: "x", title: "X", artist: "Ex", seconds: 30),
            record(day: 3, key: "x", title: "X", artist: "Ex", seconds: 30),
            record(day: 1, key: "y", title: "Y", artist: "Why", seconds: 30),
            record(day: 2, key: "y", title: "Y", artist: "Why", seconds: 30),
        ]
        let capsule = build(records: current, previous: previous)

        XCTAssertEqual(capsule.songMovement["z"], .up(2))
        XCTAssertEqual(capsule.songMovement["x"], .new)
    }

    // MARK: - Time data and archetype

    func testNoTimeDataWhenSecondsAllZero() {
        let records = [
            record(day: 2, key: "a", title: "A", artist: "Artist A", seconds: 0),
            record(day: 3, key: "b", title: "B", artist: "Artist B", seconds: 0),
        ]
        let capsule = build(records: records)

        XCTAssertFalse(capsule.hasTimeData)
        XCTAssertNil(capsule.secondsChange)
        // Peak falls back to plays when time data is missing.
        XCTAssertNotNil(capsule.peakPart)
    }

    func testArchetypeExplorer() {
        // Every song is brand new this month → discoveryRate 1.0.
        let records = [
            record(day: 2, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 3, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 4, key: "b", title: "B", artist: "Artist B", seconds: 30),
        ]
        let firstPlays: [String: Date] = [
            "a": calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!,
            "b": calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!,
        ]
        let capsule = build(records: records, firstPlayByKey: firstPlays)

        XCTAssertEqual(capsule.archetype, .explorer)
        XCTAssertEqual(capsule.discoveries.count, 2)
    }

    func testArchetypeReplayer() {
        // One song 5 of 6 plays; every key predates the month → no discoveries.
        let records = [
            record(day: 1, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 2, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 3, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 4, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 5, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 6, key: "b", title: "B", artist: "Artist B", seconds: 30),
        ]
        let firstPlays: [String: Date] = [
            "a": calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!,
            "b": calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!,
        ]
        let capsule = build(records: records, firstPlayByKey: firstPlays)

        XCTAssertEqual(capsule.archetype, .replayer)
        XCTAssertTrue(capsule.discoveries.isEmpty)
    }

    func testArchetypeQuiet() {
        let capsule = build(records: [])

        XCTAssertEqual(capsule.archetype, .quiet)
        XCTAssertEqual(capsule.totalPlays, 0)
        XCTAssertNil(capsule.peakPart)
        XCTAssertEqual(capsule.longestStreakDays, 0)
        XCTAssertTrue(capsule.milestones.isEmpty)
    }

    // MARK: - Formatting

    func testDurationLabel() {
        XCTAssertEqual(ListeningCapsule.durationLabel(seconds: 0), "0 min")
        XCTAssertEqual(ListeningCapsule.durationLabel(seconds: 58), "58 sec")
        XCTAssertEqual(ListeningCapsule.durationLabel(seconds: 754), "12 min")
        XCTAssertEqual(ListeningCapsule.durationLabel(seconds: 3600), "1 hr")
        XCTAssertEqual(ListeningCapsule.durationLabel(seconds: 7830), "2 hr 10 min")
    }

    func testDeltaLabel() {
        XCTAssertEqual(ListeningCapsule.deltaLabel(0.2345), "+23%")
        XCTAssertEqual(ListeningCapsule.deltaLabel(-0.12), "-12%")
        XCTAssertEqual(ListeningCapsule.deltaLabel(0), "+0%")
    }

    // MARK: - Pairing

    func testPairingCountsBackToBackPlays() {
        let records = [
            record(day: 1, hour: 0, minute: 0, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 1, hour: 0, minute: 10, key: "b", title: "B", artist: "Artist B", seconds: 30),
            record(day: 1, hour: 0, minute: 20, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 1, hour: 0, minute: 30, key: "b", title: "B", artist: "Artist B", seconds: 30),
        ]
        let capsule = build(records: records)

        XCTAssertEqual(capsule.pairing?.count, 3)
        XCTAssertEqual(capsule.pairing?.first, "Artist A")
        XCTAssertEqual(capsule.pairing?.second, "Artist B")
    }

    func testPairingRequiresThirtyMinuteGap() {
        let records = [
            record(day: 1, hour: 0, minute: 0, key: "a", title: "A", artist: "Artist A", seconds: 30),
            record(day: 1, hour: 2, minute: 0, key: "b", title: "B", artist: "Artist B", seconds: 30),
        ]
        let capsule = build(records: records)

        XCTAssertNil(capsule.pairing)
    }

    // MARK: - Milestones

    func testHourMilestoneCrossedThisMonth() {
        // Lifetime before March: 9.9 hours; March adds 30 min → crossed 10 h.
        let lifetime = LifetimeTotals(
            seconds: 9 * 3600 + 30 * 60 + 30 * 60,
            plays: 100,
            playsBySong: [:],
            playsByArtist: [:],
            titleBySong: [:]
        )
        let records = [record(day: 2, key: "a", title: "A", artist: "Artist A", seconds: 30 * 60)]
        let capsule = build(records: records, lifetime: lifetime)

        XCTAssertTrue(capsule.milestones.contains {
            $0.headline == "10 hours of music" && $0.symbol == "clock.badge.checkmark.fill"
        })
    }

    func testSongMilestoneCappedAtHighestCrossed() {
        // Song "A" had 24 lifetime plays before March; 26 more in March → crossed 25 and 50.
        let lifetime = LifetimeTotals(
            seconds: 0,
            plays: 50,
            playsBySong: ["a": 50],
            playsByArtist: ["Artist A": 50],
            titleBySong: ["a": "A"]
        )
        let records = (1...26).map { record(day: $0, key: "a", title: "A", artist: "Artist A", seconds: 30) }
        let capsule = build(records: records, lifetime: lifetime)

        XCTAssertTrue(capsule.milestones.contains { $0.headline == "50× A" })
        XCTAssertFalse(capsule.milestones.contains { $0.headline == "25× A" })
    }
}
