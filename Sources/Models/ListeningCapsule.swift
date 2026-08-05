import Foundation

/// One play row as read from the stats database.
struct PlayRecord: Equatable {
    let playedAt: Date
    let songKey: String
    let videoID: String?
    let title: String
    let artist: String
    let isCover: Bool
    let seconds: Int
}

/// Lifetime aggregates up to (and including) a month's end — milestone inputs.
struct LifetimeTotals: Equatable {
    let seconds: Int
    let plays: Int
    let playsBySong: [String: Int]     // songKey → lifetime plays
    let playsByArtist: [String: Int]
    let titleBySong: [String: String]  // songKey → most recent title, for milestone copy
}

struct SongStat: Identifiable, Equatable {
    let id: String                     // songKey
    let title: String
    let artist: String
    let videoID: String?
    let plays: Int
    let seconds: Int
}

struct ArtistStat: Identifiable, Equatable {
    var id: String { artist }
    let artist: String
    let plays: Int
    let seconds: Int
    let topSongTitle: String?          // that artist's most-played song this month
}

enum DayPart: String, CaseIterable, Equatable {
    case morning, afternoon, evening, night

    /// morning 5–11, afternoon 12–16, evening 17–21, night 22–4
    static func of(hour: Int) -> DayPart {
        switch hour {
        case 5...11: return .morning
        case 12...16: return .afternoon
        case 17...21: return .evening
        default: return .night
        }
    }

    var label: String {
        switch self {
        case .morning: return "Mornings"
        case .afternoon: return "Afternoons"
        case .evening: return "Evenings"
        case .night: return "Nights"
        }
    }

    var symbol: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening: return "sunset.fill"
        case .night: return "moon.stars.fill"
        }
    }
}

enum RankMovement: Equatable {
    case new
    case up(Int)
    case down(Int)
    case same
}

enum Archetype: String, Equatable {
    case quiet, explorer, replayer, voyager, devotee, regular

    var title: String {
        switch self {
        case .quiet: return "Quiet Month"
        case .explorer: return "The Explorer"
        case .replayer: return "The Replayer"
        case .voyager: return "The Voyager"
        case .devotee: return "The Devotee"
        case .regular: return "The Regular"
        }
    }

    var blurb: String {
        switch self {
        case .quiet: return "Nothing logged yet. Press play."
        case .explorer: return "Most of what you played this month was brand new to you."
        case .replayer: return "You found one song and refused to let go."
        case .voyager: return "You spread your listening across a wide field of artists."
        case .devotee: return "One artist owned your month."
        case .regular: return "A steady month — familiar favourites, a little room for new things."
        }
    }

    var symbol: String {
        switch self {
        case .quiet: return "moon.zzz.fill"
        case .explorer: return "safari.fill"
        case .replayer: return "repeat.circle.fill"
        case .voyager: return "globe.americas.fill"
        case .devotee: return "heart.fill"
        case .regular: return "waveform"
        }
    }
}

struct Milestone: Identifiable, Equatable {
    var id: String { headline }
    let headline: String
    let detail: String
    let symbol: String
}

/// An unordered pair of artists heard back-to-back, stored alphabetically.
struct Pairing: Equatable {
    let first: String
    let second: String
    let count: Int
}

/// A month's aggregated listening, built purely from play rows.
struct ListeningCapsule: Equatable {
    let monthStart: Date
    let totalPlays: Int
    let totalSeconds: Int
    /// false when the month has plays but zero recorded seconds — data predates
    /// seconds tracking, so the hero card headlines plays instead of time.
    let hasTimeData: Bool
    let distinctSongs: Int
    let distinctArtists: Int
    let topSongs: [SongStat]           // ≤ 5
    let topArtists: [ArtistStat]       // ≤ 5
    let allSongs: [SongStat]           // full ranking, for the drill-down
    let allArtists: [ArtistStat]
    let secondsByDay: [Int]            // one entry per day in the month, index 0 = day 1
    let playsByDay: [Int]              // same length; used when hasTimeData == false
    let dailyAverageSeconds: Int       // totalSeconds / days elapsed
    let secondsByPart: [DayPart: Int]
    let playsByPart: [DayPart: Int]
    let peakPart: DayPart?
    let activeDays: Int
    let longestStreakDays: Int
    let discoveries: [SongStat]        // songs whose first-ever play is in this month
    let pairing: Pairing?
    let playsChange: Double?           // fraction vs previous month; nil if previous month empty
    let secondsChange: Double?
    let songMovement: [String: RankMovement]   // songKey → movement vs previous month
    let artistMovement: [String: RankMovement] // artist → movement
    let archetype: Archetype
    let milestones: [Milestone]

    static let empty = ListeningCapsule(
        monthStart: .distantPast,
        totalPlays: 0,
        totalSeconds: 0,
        hasTimeData: true,
        distinctSongs: 0,
        distinctArtists: 0,
        topSongs: [],
        topArtists: [],
        allSongs: [],
        allArtists: [],
        secondsByDay: [],
        playsByDay: [],
        dailyAverageSeconds: 0,
        secondsByPart: [:],
        playsByPart: [:],
        peakPart: nil,
        activeDays: 0,
        longestStreakDays: 0,
        discoveries: [],
        pairing: nil,
        playsChange: nil,
        secondsChange: nil,
        songMovement: [:],
        artistMovement: [:],
        archetype: .quiet,
        milestones: []
    )

    static func build(
        monthStart: Date,
        records: [PlayRecord],
        previous: [PlayRecord],
        lifetimeAtMonthEnd: LifetimeTotals,
        firstPlayByKey: [String: Date],
        now: Date,
        calendar: Calendar
    ) -> ListeningCapsule {
        // 1. Totals
        let totalPlays = records.count
        let totalSeconds = records.reduce(0) { $0 + $1.seconds }
        let hasTimeData = totalSeconds > 0 || records.isEmpty

        // 2. Songs — group by songKey; sort plays desc, seconds desc, latest playedAt desc.
        let songsByKey = Dictionary(grouping: records, by: \.songKey)
        let songGroups: [(stat: SongStat, latest: Date)] = songsByKey.values.map { group in
            let latest = group.max { $0.playedAt < $1.playedAt }!
            return (
                SongStat(
                    id: latest.songKey,
                    title: latest.title,
                    artist: latest.artist,
                    videoID: latest.videoID,
                    plays: group.count,
                    seconds: group.reduce(0) { $0 + $1.seconds }
                ),
                latest.playedAt
            )
        }
        let allSongs = songGroups
            .sorted {
                if $0.stat.plays != $1.stat.plays { return $0.stat.plays > $1.stat.plays }
                if $0.stat.seconds != $1.stat.seconds { return $0.stat.seconds > $1.stat.seconds }
                return $0.latest > $1.latest
            }
            .map(\.stat)
        let topSongs = Array(allSongs.prefix(5))
        let distinctSongs = allSongs.count

        // 3. Artists — exact-string grouping, same sort; topSongTitle is the
        //    artist's highest-ranked song in the month.
        let byArtist = Dictionary(grouping: records, by: \.artist)
        let artistGroups: [(stat: ArtistStat, latest: Date)] = byArtist.values.map { group in
            let latest = group.max { $0.playedAt < $1.playedAt }!
            return (
                ArtistStat(
                    artist: latest.artist,
                    plays: group.count,
                    seconds: group.reduce(0) { $0 + $1.seconds },
                    topSongTitle: allSongs.first { $0.artist == latest.artist }?.title
                ),
                latest.playedAt
            )
        }
        let allArtists = artistGroups
            .sorted {
                if $0.stat.plays != $1.stat.plays { return $0.stat.plays > $1.stat.plays }
                if $0.stat.seconds != $1.stat.seconds { return $0.stat.seconds > $1.stat.seconds }
                return $0.latest > $1.latest
            }
            .map(\.stat)
        let topArtists = Array(allArtists.prefix(5))
        let distinctArtists = allArtists.count

        // 4. Per-day arrays
        let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        var secondsByDay = [Int](repeating: 0, count: dayCount)
        var playsByDay = [Int](repeating: 0, count: dayCount)
        for record in records {
            let day = calendar.component(.day, from: record.playedAt) - 1
            guard day >= 0, day < dayCount else { continue }
            secondsByDay[day] += record.seconds
            playsByDay[day] += 1
        }

        // 5. Daily average — denominator is days elapsed for the current month.
        let elapsedDays = calendar.isDate(now, equalTo: monthStart, toGranularity: .month)
            ? calendar.component(.day, from: now)
            : dayCount
        let dailyAverageSeconds = dayCount == 0 ? 0 : totalSeconds / max(1, elapsedDays)

        // 6. Day parts — ties break in DayPart.allCases order.
        var secondsByPart: [DayPart: Int] = [:]
        var playsByPart: [DayPart: Int] = [:]
        for record in records {
            let part = DayPart.of(hour: calendar.component(.hour, from: record.playedAt))
            secondsByPart[part, default: 0] += record.seconds
            playsByPart[part, default: 0] += 1
        }
        let peakPart: DayPart? = records.isEmpty ? nil : (hasTimeData ? secondsByPart : playsByPart)
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return DayPart.allCases.firstIndex(of: lhs.key)! > DayPart.allCases.firstIndex(of: rhs.key)!
            }?
            .key

        // 7. Active days / streak — within the month only.
        let activeDays = Set(records.map { calendar.component(.day, from: $0.playedAt) }).count
        var longestStreakDays = 0
        var currentStreak = 0
        var previousDay: Int?
        for day in Set(records.map { calendar.component(.day, from: $0.playedAt) }).sorted() {
            currentStreak = (previousDay != nil && day == previousDay! + 1) ? currentStreak + 1 : 1
            longestStreakDays = max(longestStreakDays, currentStreak)
            previousDay = day
        }
        // ponytail: a streak spanning a month boundary is not chased.

        // 8. Discoveries — first-ever play inside the month; allSongs order is
        //    already plays desc.
        let monthInterval = calendar.dateInterval(of: .month, for: monthStart)!
        let discoveries = allSongs.filter { stat in
            guard let first = firstPlayByKey[stat.id] else { return false }
            return monthInterval.contains(first)
        }

        // 9. Month-over-month deltas
        let playsChange: Double? = previous.isEmpty
            ? nil
            : (Double(totalPlays) - Double(previous.count)) / Double(previous.count)
        let previousSeconds = previous.reduce(0) { $0 + $1.seconds }
        let secondsChange: Double? = previousSeconds == 0
            ? nil
            : (Double(totalSeconds) - Double(previousSeconds)) / Double(previousSeconds)

        // 10. Rank movement vs the previous month's full rankings
        func rankedKeys(_ records: [PlayRecord], byKey: (PlayRecord) -> String) -> [String] {
            let groups = Dictionary(grouping: records, by: byKey)
            return groups.keys.sorted { a, b in
                let ga = groups[a]!, gb = groups[b]!
                if ga.count != gb.count { return ga.count > gb.count }
                let sa = ga.reduce(0) { $0 + $1.seconds }, sb = gb.reduce(0) { $0 + $1.seconds }
                if sa != sb { return sa > sb }
                return (ga.map(\.playedAt).max() ?? .distantPast) > (gb.map(\.playedAt).max() ?? .distantPast)
            }
        }
        let previousSongRanks = rankedKeys(previous, byKey: \.songKey)
        let previousArtistRanks = rankedKeys(previous, byKey: \.artist)

        func movements<Stat: Identifiable>(top: [Stat], previousRanks: [String]) -> [String: RankMovement] where Stat.ID == String {
            var result: [String: RankMovement] = [:]
            for (index, stat) in top.enumerated() {
                if let previousIndex = previousRanks.firstIndex(of: stat.id) {
                    let delta = previousIndex - index
                    result[stat.id] = delta == 0 ? .same : (delta > 0 ? .up(delta) : .down(-delta))
                } else {
                    result[stat.id] = .new
                }
            }
            return result
        }
        let songMovement = movements(top: topSongs, previousRanks: previousSongRanks)
        let artistMovement = movements(top: topArtists, previousRanks: previousArtistRanks)

        // 11. Archetype — first matching rule wins
        let repeatRate = Double(topSongs.first?.plays ?? 0) / Double(max(1, totalPlays))
        let loyalty = Double(topArtists.first?.plays ?? 0) / Double(max(1, totalPlays))
        let discoveryRate = Double(discoveries.count) / Double(max(1, distinctSongs))
        let archetype: Archetype
        if totalPlays == 0 {
            archetype = .quiet
        } else if discoveryRate >= 0.5 {
            archetype = .explorer
        } else if repeatRate >= 0.25 {
            archetype = .replayer
        } else if loyalty >= 0.4 {
            archetype = .devotee
        } else if distinctArtists >= 25 {
            archetype = .voyager
        } else {
            archetype = .regular
        }

        // 12. Milestones — threshold crossed during this month, highest per
        //     category, in order: hours, songs, artists, streak.
        var milestones: [Milestone] = []
        if lifetimeAtMonthEnd.seconds > 0 {
            let lifetimeStartSeconds = lifetimeAtMonthEnd.seconds - totalSeconds
            if let t = [10, 25, 50, 100, 250, 500, 1000].last(where: {
                lifetimeStartSeconds < $0 * 3600 && $0 * 3600 <= lifetimeAtMonthEnd.seconds
            }) {
                milestones.append(Milestone(
                    headline: "\(t) hours of music",
                    detail: "Lifetime listening passed \(t) hours this month.",
                    symbol: "clock.badge.checkmark.fill"
                ))
            }
        }
        for song in allSongs {
            let lifetimeEnd = lifetimeAtMonthEnd.playsBySong[song.id] ?? 0
            let lifetimeStart = lifetimeEnd - song.plays
            if let t = [25, 50, 100].last(where: { lifetimeStart < $0 && $0 <= lifetimeEnd }),
               let title = lifetimeAtMonthEnd.titleBySong[song.id] {
                milestones.append(Milestone(
                    headline: "\(t)× \(title)",
                    detail: "You have played it \(lifetimeEnd) times in total.",
                    symbol: "music.note"
                ))
            }
        }
        for artist in allArtists {
            let lifetimeEnd = lifetimeAtMonthEnd.playsByArtist[artist.artist] ?? 0
            let lifetimeStart = lifetimeEnd - artist.plays
            if let t = [50, 100, 250].last(where: { lifetimeStart < $0 && $0 <= lifetimeEnd }) {
                milestones.append(Milestone(
                    headline: "\(t) plays of \(artist.artist)",
                    detail: "That is \(lifetimeEnd) plays all-time.",
                    symbol: "person.fill.checkmark"
                ))
            }
        }
        if let t = [7, 14, 30].last(where: { longestStreakDays >= $0 }) {
            milestones.append(Milestone(
                headline: "\(t)-day streak",
                detail: "You listened every day for \(longestStreakDays) days straight.",
                symbol: "flame.fill"
            ))
        }

        // 13. Pairing — adjacent plays of different artists within 30 minutes.
        let ordered = records.sorted { $0.playedAt < $1.playedAt }
        struct PairKey: Hashable { let a: String; let b: String }
        var pairCounts: [PairKey: Int] = [:]
        for (first, second) in zip(ordered, ordered.dropFirst()) {
            guard first.artist != second.artist,
                  second.playedAt.timeIntervalSince(first.playedAt) < 30 * 60 else { continue }
            let names = [first.artist, second.artist].sorted()
            pairCounts[PairKey(a: names[0], b: names[1]), default: 0] += 1
        }
        let pairing: Pairing? = pairCounts
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return (lhs.key.a, lhs.key.b) < (rhs.key.a, rhs.key.b)
            }
            .flatMap { $0.value >= 2 ? Pairing(first: $0.key.a, second: $0.key.b, count: $0.value) : nil }

        return ListeningCapsule(
            monthStart: monthStart,
            totalPlays: totalPlays,
            totalSeconds: totalSeconds,
            hasTimeData: hasTimeData,
            distinctSongs: distinctSongs,
            distinctArtists: distinctArtists,
            topSongs: topSongs,
            topArtists: topArtists,
            allSongs: allSongs,
            allArtists: allArtists,
            secondsByDay: secondsByDay,
            playsByDay: playsByDay,
            dailyAverageSeconds: dailyAverageSeconds,
            secondsByPart: secondsByPart,
            playsByPart: playsByPart,
            peakPart: peakPart,
            activeDays: activeDays,
            longestStreakDays: longestStreakDays,
            discoveries: discoveries,
            pairing: pairing,
            playsChange: playsChange,
            secondsChange: secondsChange,
            songMovement: songMovement,
            artistMovement: artistMovement,
            archetype: archetype,
            milestones: milestones
        )
    }
}

extension ListeningCapsule {
    /// 0 → "0 min"; 58 → "58 sec"; 754 → "12 min"; 3600 → "1 hr"; 7830 → "2 hr 10 min"
    static func durationLabel(seconds: Int) -> String {
        if seconds <= 0 { return "0 min" }
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    /// 0.2345 → "+23%"; -0.12 → "-12%"; 0 → "+0%"
    static func deltaLabel(_ fraction: Double) -> String {
        String(format: "%+.0f%%", fraction * 100)
    }
}
