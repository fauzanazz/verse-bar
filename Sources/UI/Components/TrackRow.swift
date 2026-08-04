import SwiftUI

/// List row used by Home and Library: artwork, title/artist/subtitle, hover
/// play button, and an actions menu (Play Next / Add to Queue / Reveal /
/// Delete).
struct TrackRow: View {
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    let track: LibraryTrack
    let subtitle: String
    let isCurrent: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @ObservedObject private var separation = VocalSeparationService.shared

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if separation.isBusy(with: track) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(separation.progressLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            } else if VocalSeparationService.hasInstrumental(for: track) {
                Image(systemName: "music.mic")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .help("Instrumental available")
            }

            if isHovering || isCurrent {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Play")
            }

            Menu {
                Button("Play Next", action: onPlayNext)
                Button("Add to Queue", action: onAddToQueue)
                Divider()
                if VocalSeparationService.hasInstrumental(for: track) {
                    Button("Remove Instrumental") { separation.removeInstrumental(for: track) }
                } else {
                    Button("Create Instrumental (Karaoke)") { separation.separate(track) }
                        .disabled(separation.isBusy || VocalSeparationService.availability() == .unavailable)
                }
                Divider()
                Button("Reveal in Finder", action: onReveal)
                Button("Delete from Library", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(
            isCurrent
                ? Color.accentColor.opacity(0.08)
                : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering in isHovering = hovering }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var artwork: some View {
        if let image = LibraryService.shared.artwork(for: track) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
