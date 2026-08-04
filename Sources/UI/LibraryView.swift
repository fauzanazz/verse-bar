import SwiftUI

/// Shared sort for the Library / Home track lists. Declared here once, reused
/// by HomeView.
enum LibrarySort: String, CaseIterable, Identifiable {
    case added, lastPlayed, title, artist
    var id: String { rawValue }
    var label: String {
        switch self {
        case .added: return "Recently Added"
        case .lastPlayed: return "Last Played"
        case .title: return "Title"
        case .artist: return "Artist"
        }
    }
}

struct LibrarySortMenu: View {
    @Binding var sort: LibrarySort

    var body: some View {
        Menu {
            ForEach(LibrarySort.allCases) { option in
                Button(option.label) { sort = option }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sort.label)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct LibraryView: View {
    @ObservedObject private var library = LibraryService.shared
    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @State private var query = ""
    @State private var sort: LibrarySort = .added
    @State private var trackToDelete: LibraryTrack?

    private var filtered: [LibraryTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [LibraryTrack]
        switch sort {
        case .added:
            base = library.tracks
        case .lastPlayed:
            let lastPlayed = ListeningStatsService.shared.lastPlayedByKey()
            base = library.tracks.sorted {
                (lastPlayed[$0.statsKey] ?? .distantPast) > (lastPlayed[$1.statsKey] ?? .distantPast)
            }
        case .title:
            base = library.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            base = library.tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library")
                .font(.system(size: 34, weight: .bold))

            HStack(spacing: 10) {
                searchField
                Spacer()
                LibrarySortMenu(sort: $sort)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text(library.tracks.isEmpty ? "Library kosong." : "Tidak ada lagu yang cocok.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.top, 60)
                    } else {
                        ForEach(filtered) { track in
                            TrackRow(
                                track: track,
                                subtitle: subtitle(for: track),
                                isCurrent: audioPlayer.queue.current?.id == track.id,
                                onPlay: { play(track) },
                                onPlayNext: { audioPlayer.playNext(track) },
                                onAddToQueue: { audioPlayer.addToQueue(track) },
                                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([track.url]) },
                                onDelete: { trackToDelete = track }
                            )
                        }
                    }
                }
            }

            Text("\(filtered.count) songs")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .confirmationDialog("Hapus dari Library?", isPresented: deleteDialogPresented, presenting: trackToDelete) { track in
            Button("Hapus", role: .destructive) { library.delete(track) }
        } message: { track in
            Text("“\(track.title)” akan dipindahkan ke Trash.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("Cari lagu atau artis", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .clipShape(Capsule())
        .frame(maxWidth: 360)
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { trackToDelete != nil },
            set: { if !$0 { trackToDelete = nil } }
        )
    }

    private func subtitle(for track: LibraryTrack) -> String {
        if sort == .lastPlayed,
           let date = ListeningStatsService.shared.lastPlayedByKey()[track.statsKey] {
            return "Played \(TrackRow.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "Added \(TrackRow.relativeFormatter.localizedString(for: track.addedAt, relativeTo: Date()))"
    }

    private func play(_ track: LibraryTrack) {
        guard let index = filtered.firstIndex(where: { $0.id == track.id }) else { return }
        audioPlayer.play(filtered, startAt: index)
    }
}
