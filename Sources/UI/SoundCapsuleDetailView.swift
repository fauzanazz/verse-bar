import SwiftUI

enum CapsuleDetail: String, Identifiable {
    case songs, artists, time, discoveries
    var id: String { rawValue }
}

/// Drill-down sheet for a capsule card. Presented as a sheet because the pane
/// lives inside a NavigationSplitView detail column.
struct SoundCapsuleDetailView: View {
    let detail: CapsuleDetail
    let capsule: ListeningCapsule
    let libraryByKey: [String: LibraryTrack]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                content
                    .padding(16)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var title: String {
        switch detail {
        case .songs: return "Top Songs"
        case .artists: return "Top Artists"
        case .time: return "Listening Time"
        case .discoveries: return "New to You"
        }
    }

    @ViewBuilder private var content: some View {
        switch detail {
        case .songs: songsList
        case .artists: artistsList
        case .time: timeDetail
        case .discoveries: discoveriesList
        }
    }

    // MARK: - Songs

    private var songsList: some View {
        Group {
            if capsule.allSongs.isEmpty {
                emptyText
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(Array(capsule.allSongs.enumerated()), id: \.element.id) { index, song in
                        HStack(spacing: 10) {
                            rankText(index)
                            CapsuleArtwork(stat: song, libraryByKey: libraryByKey)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(song.artist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(song.plays)×")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(ListeningCapsule.durationLabel(seconds: song.seconds))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            MovementGlyph(movement: capsule.songMovement[song.id])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Artists

    private var artistsList: some View {
        Group {
            if capsule.allArtists.isEmpty {
                emptyText
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(Array(capsule.allArtists.enumerated()), id: \.element.id) { index, artist in
                        HStack(spacing: 10) {
                            rankText(index)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.artist)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if let topSongTitle = artist.topSongTitle {
                                    Text(topSongTitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(ListeningCapsule.durationLabel(seconds: artist.seconds))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text("\(artist.plays) plays")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            MovementGlyph(movement: capsule.artistMovement[artist.id])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Time

    private var timeDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            DayChart(values: capsule.hasTimeData ? capsule.secondsByDay : capsule.playsByDay, height: 140)

            VStack(spacing: 8) {
                statRow("Total", ListeningCapsule.durationLabel(seconds: capsule.totalSeconds))
                statRow("Daily average", ListeningCapsule.durationLabel(seconds: capsule.dailyAverageSeconds))
                statRow("Busiest day", busiestDayLabel)
                statRow("Active days", "\(capsule.activeDays)")
                statRow("Longest streak", capsule.longestStreakDays > 0 ? "\(capsule.longestStreakDays) days" : "—")
                statRow("Peak time", capsule.peakPart?.label ?? "—")
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(DayPart.allCases, id: \.self) { part in
                    HStack(spacing: 8) {
                        Text(part.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor.opacity(part == capsule.peakPart ? 0.9 : 0.35))
                                .frame(width: max(2, share(of: part) * geo.size.width))
                        }
                        .frame(height: 6)
                        Text(ListeningCapsule.durationLabel(seconds: capsule.secondsByPart[part] ?? 0))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }

    private var busiestDayLabel: String {
        let values = capsule.hasTimeData ? capsule.secondsByDay : capsule.playsByDay
        guard let maxValue = values.max(), maxValue > 0,
              let index = values.firstIndex(of: maxValue) else { return "—" }
        let date = capsule.monthStart.addingTimeInterval(TimeInterval(index) * 86400)
        return Self.dayFormatter.string(from: date)
    }

    private func share(of part: DayPart) -> Double {
        let value = capsule.hasTimeData
            ? Double(capsule.secondsByPart[part] ?? 0)
            : Double(capsule.playsByPart[part] ?? 0)
        let total = capsule.hasTimeData
            ? Double(capsule.totalSeconds)
            : Double(capsule.totalPlays)
        return value / max(1, total)
    }

    // MARK: - Discoveries

    private var discoveriesList: some View {
        Group {
            if capsule.discoveries.isEmpty {
                emptyText
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(capsule.discoveries) { song in
                        HStack(spacing: 10) {
                            CapsuleArtwork(stat: song, libraryByKey: libraryByKey)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(song.artist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(song.plays)×")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared

    private var emptyText: some View {
        Text("Nothing here for this month.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func rankText(_ index: Int) -> some View {
        Text("\(index + 1)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 16, alignment: .trailing)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()
}
