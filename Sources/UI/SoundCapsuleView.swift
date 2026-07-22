import SwiftUI

struct SoundCapsuleView: View {
    @State private var monthStart: Date
    @State private var filter: CoverFilter = .all
    @State private var capsule = ListeningCapsule(totalPlays: 0, topSongs: [], topArtists: [])

    private let calendar = Calendar.current

    init() {
        _monthStart = State(initialValue: Calendar.current.dateInterval(of: .month, for: Date())!.start)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                monthPicker

                Picker("", selection: $filter) {
                    Text("All").tag(CoverFilter.all)
                    Text("Original").tag(CoverFilter.original)
                    Text("Cover").tag(CoverFilter.cover)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                VStack(spacing: 2) {
                    Text(capsule.totalPlays.formatted())
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("plays this month")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                statsSection(title: "TOP SONGS", isEmpty: capsule.topSongs.isEmpty) {
                    ForEach(Array(capsule.topSongs.enumerated()), id: \.element.id) { index, song in
                        HStack(spacing: 10) {
                            rank(index + 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
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

                statsSection(title: "TOP ARTISTS", isEmpty: capsule.topArtists.isEmpty) {
                    ForEach(Array(capsule.topArtists.enumerated()), id: \.element.id) { index, artist in
                        HStack(spacing: 10) {
                            rank(index + 1)
                            Text(artist.artist)
                                .lineLimit(1)
                            Spacer()
                            Text("\(artist.plays)×")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: monthStart) { _, _ in reload() }
        .onChange(of: filter) { _, _ in reload() }
    }

    private var monthPicker: some View {
        HStack {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            Spacer()
            Text(Self.monthFormatter.string(from: monthStart))
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()

            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
        }
        .padding(.horizontal, 4)
    }

    private func statsSection<Content: View>(
        title: String,
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                if isEmpty {
                    Text("No plays yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
                } else {
                    content()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func rank(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 18)
    }

    private var isCurrentMonth: Bool {
        monthStart >= calendar.dateInterval(of: .month, for: Date())!.start
    }

    private func moveMonth(by value: Int) {
        guard let date = calendar.date(byAdding: .month, value: value, to: monthStart),
              let start = calendar.dateInterval(of: .month, for: date)?.start else { return }
        monthStart = start
    }

    private func reload() {
        capsule = ListeningStatsService.shared.capsule(monthStart: monthStart, filter: filter)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}
