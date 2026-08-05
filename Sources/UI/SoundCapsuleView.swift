import SwiftUI

/// The Sound Capsule pane: a monthly card deck of listening stats.
struct SoundCapsuleView: View {
    @State private var monthStart: Date
    @State private var filter: CoverFilter = .all
    @State private var capsule: ListeningCapsule = .empty
    @State private var months: [Date] = []
    @State private var detail: CapsuleDetail?
    @ObservedObject private var library = LibraryService.shared

    init() {
        _monthStart = State(initialValue: Calendar.current.dateInterval(of: .month, for: Date())!.start)
    }

    /// statsKey → LibraryTrack, built once per render for artwork lookups.
    private var libraryByKey: [String: LibraryTrack] {
        Dictionary(library.tracks.map { ($0.statsKey, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                monthStrip
                filterPicker

                if capsule.totalPlays == 0 {
                    emptyState
                } else {
                    heroCard
                    topSongsCard
                    topArtistsCard
                    listeningTimeCard
                    if capsule.peakPart != nil { timeOfDayCard }
                    archetypeCard
                    if !capsule.milestones.isEmpty { milestonesCard }
                    if !capsule.discoveries.isEmpty { discoveriesCard }
                    if capsule.pairing != nil { pairingCard }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: monthStart) { _, _ in reload() }
        .onChange(of: filter) { _, _ in reload() }
        .sheet(item: $detail) { detail in
            SoundCapsuleDetailView(
                detail: detail,
                capsule: capsule,
                libraryByKey: libraryByKey,
                onClose: { self.detail = nil }
            )
        }
    }

    // MARK: - Month strip

    private var monthStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(months, id: \.self) { month in
                        Button {
                            monthStart = month
                        } label: {
                            Text(Self.pillFormatter.string(from: month))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        month == monthStart ? Color.accentColor : Color.primary.opacity(0.07)
                                    )
                                )
                                .foregroundStyle(month == monthStart ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(month)
                    }
                }
            }
            .onAppear { proxy.scrollTo(monthStart, anchor: .center) }
            .onChange(of: monthStart) { _, newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            Text("All").tag(CoverFilter.all)
            Text("Original").tag(CoverFilter.original)
            Text("Cover").tag(CoverFilter.cover)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    // MARK: - Cards

    private var heroCard: some View {
        CapsuleCard(title: nil, trailing: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.monthFormatter.string(from: capsule.monthStart))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(capsule.hasTimeData
                        ? ListeningCapsule.durationLabel(seconds: capsule.totalSeconds)
                        : capsule.totalPlays.formatted())
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text(capsule.hasTimeData ? "listened" : "plays")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("\(capsule.totalPlays.formatted()) plays · \(capsule.distinctSongs) songs · \(capsule.distinctArtists) artists")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !capsule.hasTimeData {
                    Text("Listening time isn't recorded for this month.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if let change = capsule.hasTimeData ? capsule.secondsChange : capsule.playsChange {
                    HStack(spacing: 4) {
                        Text(ListeningCapsule.deltaLabel(change))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(change >= 0 ? Color.green : Color.orange)
                        Text("vs last month")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    private var topSongsCard: some View {
        CapsuleCard(title: "Top Songs", trailing: "5 of \(capsule.distinctSongs)", onTap: { detail = .songs }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(capsule.topSongs.enumerated()), id: \.element.id) { index, song in
                    songRow(index: index, song: song, showSeconds: false)
                }
            }
        }
    }

    private var topArtistsCard: some View {
        CapsuleCard(title: "Top Artists", trailing: "5 of \(capsule.distinctArtists)", onTap: { detail = .artists }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(capsule.topArtists.enumerated()), id: \.element.id) { index, artist in
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
                        if capsule.hasTimeData {
                            Text(ListeningCapsule.durationLabel(seconds: artist.seconds))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(artist.plays)×")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        MovementGlyph(movement: capsule.artistMovement[artist.id])
                    }
                }
            }
        }
    }

    private var listeningTimeCard: some View {
        CapsuleCard(title: "Listening Time", onTap: { detail = .time }) {
            VStack(alignment: .leading, spacing: 10) {
                DayChart(values: capsule.hasTimeData ? capsule.secondsByDay : capsule.playsByDay)
                HStack {
                    Text("Daily average")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ListeningCapsule.durationLabel(seconds: capsule.dailyAverageSeconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                HStack {
                    Text("Active days")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(capsule.activeDays)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    private var timeOfDayCard: some View {
        CapsuleCard(title: nil, trailing: nil) {
            VStack(alignment: .leading, spacing: 10) {
                if let peak = capsule.peakPart {
                    HStack(spacing: 6) {
                        Image(systemName: peak.symbol)
                            .font(.system(size: 13))
                        Text("You're a \(peak.label.lowercased()) listener")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                ForEach(DayPart.allCases, id: \.self) { part in
                    dayPartRow(part)
                }
            }
        }
    }

    private func dayPartRow(_ part: DayPart) -> some View {
        let value = capsule.hasTimeData
            ? Double(capsule.secondsByPart[part] ?? 0)
            : Double(capsule.playsByPart[part] ?? 0)
        let total = capsule.hasTimeData
            ? Double(capsule.totalSeconds)
            : Double(capsule.totalPlays)
        return HStack(spacing: 8) {
            Text(part.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(part == capsule.peakPart ? 0.9 : 0.35))
                    .frame(width: max(2, value / max(1, total) * geo.size.width))
            }
            .frame(height: 6)
        }
    }

    private var archetypeCard: some View {
        CapsuleCard(title: nil, trailing: nil) {
            HStack(spacing: 10) {
                Image(systemName: capsule.archetype.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(capsule.archetype.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(capsule.archetype.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var milestonesCard: some View {
        CapsuleCard(title: "Milestones", trailing: nil) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(capsule.milestones) { milestone in
                    HStack(spacing: 10) {
                        Image(systemName: milestone.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(milestone.headline)
                                .font(.system(size: 12, weight: .semibold))
                            Text(milestone.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var discoveriesCard: some View {
        CapsuleCard(title: "New to You", trailing: "\(capsule.discoveries.count)", onTap: { detail = .discoveries }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(capsule.discoveries.prefix(5).enumerated()), id: \.element.id) { index, song in
                    songRow(index: index, song: song, showSeconds: false)
                }
            }
        }
    }

    private var pairingCard: some View {
        CapsuleCard(title: "An Unlikely Pair", trailing: nil) {
            if let pairing = capsule.pairing {
                Text("\(pairing.first) and \(pairing.second) — played back to back \(pairing.count) times.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func songRow(index: Int, song: SongStat, showSeconds: Bool) -> some View {
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
            if showSeconds {
                Text(ListeningCapsule.durationLabel(seconds: song.seconds))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(song.plays)×")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            MovementGlyph(movement: capsule.songMovement[song.id])
        }
    }

    private func rankText(_ index: Int) -> some View {
        Text("\(index + 1)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 16, alignment: .trailing)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No plays recorded for this month.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Loading

    private func reload() {
        var months = ListeningStatsService.shared.monthsWithPlays()
        let current = Calendar.current.dateInterval(of: .month, for: Date())!.start
        if !months.contains(current) {
            months.insert(current, at: 0)
        }
        self.months = months
        capsule = ListeningStatsService.shared.capsule(monthStart: monthStart, filter: filter)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let pillFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yy"
        return formatter
    }()
}

// MARK: - Shared card chrome

private struct CapsuleCard<Content: View>: View {
    let title: String?
    var trailing: String? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    if onTap != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))

        if let onTap {
            card
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        } else {
            card
        }
    }
}

/// Song row artwork: library art when the stats key joins a downloaded file,
/// a YouTube thumbnail for `yt:` plays, else a music-note placeholder.
struct CapsuleArtwork: View {
    let stat: SongStat
    let libraryByKey: [String: LibraryTrack]
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let track = libraryByKey[stat.id],
               let image = LibraryService.shared.artwork(for: track) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let videoID = stat.videoID,
                      let url = YouTubeArtworkResolver.thumbnailURL(videoID: videoID) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Color.primary.opacity(0.05)
                    }
                }
            } else {
                ZStack {
                    Color.primary.opacity(0.05)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Rank movement vs the previous month: NEW, ▲n, ▼n, nothing.
struct MovementGlyph: View {
    let movement: RankMovement?

    var body: some View {
        switch movement {
        case .new:
            Text("NEW")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color.accentColor)
        case .up(let n):
            HStack(spacing: 1) {
                Image(systemName: "arrowtriangle.up.fill")
                Text("\(n)")
            }
            .font(.system(size: 9))
            .foregroundStyle(.green)
        case .down(let n):
            HStack(spacing: 1) {
                Image(systemName: "arrowtriangle.down.fill")
                Text("\(n)")
            }
            .font(.system(size: 9))
            .foregroundStyle(.orange)
        case .same, nil:
            EmptyView()
        }
    }
}

/// Plain-shape day chart — no Swift Charts dependency (build.sh is hand-rolled).
struct DayChart: View {
    let values: [Int]
    var height: CGFloat = 84

    var body: some View {
        let maxValue = values.max() ?? 0
        VStack(spacing: 4) {
            if maxValue > 0 {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(values.indices, id: \.self) { index in
                        let value = values[index]
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.07))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(height: value == 0 ? 0 : max(2, height * Double(value) / Double(maxValue)))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: height)
                HStack {
                    Text("1")
                    Spacer()
                    Text("\(values.count / 2)")
                    Spacer()
                    Text("\(values.count)")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            } else {
                Color.clear.frame(height: height)
            }
        }
    }
}
