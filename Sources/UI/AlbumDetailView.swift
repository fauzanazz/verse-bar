import AppKit
import SwiftUI

/// Album detail: cover/title/description header + reorderable track list.
/// Playing loads the album as the play queue via `AudioPlayerService.play`.
struct AlbumDetailView: View {
    let album: Album
    let onBack: () -> Void
    let onEdit: () -> Void

    @ObservedObject private var service = AlbumService.shared
    @ObservedObject private var audioPlayer = AudioPlayerService.shared

    /// The passed `album` goes stale after a reorder; re-read fresh each render.
    private var live: Album { service.albums.first { $0.id == album.id } ?? album }
    private var tracks: [LibraryTrack] { service.tracks(in: live) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                onBack()
            } label: {
                Label("Albums", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            header

            if tracks.isEmpty {
                Text("Album ini masih kosong. Tambahkan lagu dari Library lewat menu ⋯ → Add to Album.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.top, 40)
            } else {
                trackList
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            cover

            VStack(alignment: .leading, spacing: 6) {
                Text(live.title)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(2)
                if !live.description.isEmpty {
                    Text(live.description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                Text("\(tracks.count) songs")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 12) {
                    Button {
                        play(at: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(tracks.isEmpty)
                    Button {
                        audioPlayer.setShuffled(true)
                        play(at: 0)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .disabled(tracks.isEmpty)
                    Button("Edit", action: onEdit)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image = service.cover(for: live) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "square.stack")
                .font(.system(size: 54))
                .foregroundColor(.secondary)
                .frame(width: 180, height: 180)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var trackList: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    subtitle: track.album ?? "Added \(TrackRow.relativeFormatter.localizedString(for: track.addedAt, relativeTo: Date()))",
                    isCurrent: audioPlayer.queue.current?.id == track.id,
                    removeLabel: "Remove from Album",
                    onPlay: { play(at: index) },
                    onPlayNext: { audioPlayer.playNext(track) },
                    onAddToQueue: { audioPlayer.addToQueue(track) },
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([track.url]) },
                    onDelete: { service.removeTracks(atOffsets: IndexSet(integer: index), from: live.id) }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            .onMove { offsets, destination in
                service.moveTracks(fromOffsets: offsets, toOffset: destination, in: live.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func play(at index: Int) {
        let list = tracks
        guard list.indices.contains(index) else { return }
        audioPlayer.play(list, startAt: index)
    }
}
