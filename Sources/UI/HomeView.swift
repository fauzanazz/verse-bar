import SwiftUI

/// Home: Recently Played cards + the full library list with a sort menu.
struct HomeView: View {
    let onBrowse: () -> Void

    @ObservedObject private var library = LibraryService.shared
    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @State private var sort: LibrarySort = .added
    @State private var trackToDelete: LibraryTrack?
    @State private var hoveredRecentID: LibraryTrack.ID?

    private var lastPlayed: [String: Date] {
        ListeningStatsService.shared.lastPlayedByKey()
    }

    /// Recent plays joined back to library files by statsKey; plays with no
    /// matching file are dropped.
    private var recentlyPlayed: [(track: LibraryTrack, playedAt: Date)] {
        let byKey = Dictionary(grouping: library.tracks, by: { $0.statsKey })
            .compactMapValues(\.first)
        return ListeningStatsService.shared.recentPlays(limit: 12).compactMap { play in
            guard let track = byKey[play.songKey] else { return nil }
            return (track, play.playedAt)
        }
    }

    private var sortedTracks: [LibraryTrack] {
        switch sort {
        case .added:
            return library.tracks
        case .lastPlayed:
            return library.tracks.sorted {
                (lastPlayed[$0.statsKey] ?? .distantPast) > (lastPlayed[$1.statsKey] ?? .distantPast)
            }
        case .title:
            return library.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return library.tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Home")
                    .font(.system(size: 34, weight: .bold))

                if library.tracks.isEmpty {
                    emptyState
                } else {
                    if !recentlyPlayed.isEmpty {
                        recentlyPlayedSection
                    }
                    librarySection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Hapus dari Library?", isPresented: deleteDialogPresented, presenting: trackToDelete) { track in
            Button("Hapus", role: .destructive) { library.delete(track) }
        } message: { track in
            Text("“\(track.title)” akan dipindahkan ke Trash.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Belum ada lagu di library.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Button("Cari lagu di Browse") { onBrowse() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently Played")
                .font(.system(size: 17, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentlyPlayed, id: \.track.id) { item in
                        recentCard(item)
                    }
                }
            }
        }
    }

    private func recentCard(_ item: (track: LibraryTrack, playedAt: Date)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                artwork(item.track, width: 160)
                if hoveredRecentID == item.track.id {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            Text(item.track.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(item.track.artist)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(TrackRow.relativeFormatter.localizedString(for: item.playedAt, relativeTo: Date()))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 160, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in hoveredRecentID = hovering ? item.track.id : nil }
        .onTapGesture { playFromLibrary(item.track) }
        .contextMenu {
            Button("Play") { playFromLibrary(item.track) }
            Button("Play Next") { audioPlayer.playNext(item.track) }
            Button("Add to Queue") { audioPlayer.addToQueue(item.track) }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recently Added")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                LibrarySortMenu(sort: $sort)
            }
            LazyVStack(spacing: 8) {
                ForEach(sortedTracks) { track in
                    TrackRow(
                        track: track,
                        subtitle: subtitle(for: track),
                        isCurrent: audioPlayer.queue.current?.id == track.id,
                        onPlay: { playFromLibrary(track) },
                        onPlayNext: { audioPlayer.playNext(track) },
                        onAddToQueue: { audioPlayer.addToQueue(track) },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([track.url]) },
                        onDelete: { trackToDelete = track }
                    )
                }
            }
        }
    }

    @ViewBuilder private func artwork(_ track: LibraryTrack, width: CGFloat) -> some View {
        if let image = LibraryService.shared.artwork(for: track) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: width * 0.3))
                .foregroundColor(.secondary)
                .frame(width: width, height: width)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { trackToDelete != nil },
            set: { if !$0 { trackToDelete = nil } }
        )
    }

    private func subtitle(for track: LibraryTrack) -> String {
        if sort == .lastPlayed,
           let date = lastPlayed[track.statsKey] {
            return "Played \(TrackRow.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "Added \(TrackRow.relativeFormatter.localizedString(for: track.addedAt, relativeTo: Date()))"
    }

    /// Plays the whole visible list as the queue, starting at `track`.
    private func playFromLibrary(_ track: LibraryTrack) {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else { return }
        audioPlayer.play(sortedTracks, startAt: index)
    }
}
