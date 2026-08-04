import SwiftUI

/// Now Playing pane: artwork, title/artist and the app's synced lyrics, with
/// tap-to-seek on lyric lines (routes to the local player via PlaybackEngine).
struct NowPlayingView: View {
    let onClose: () -> Void

    @ObservedObject private var playbackEngine = PlaybackEngine.shared
    @ObservedObject private var lyricsService = LyricsService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLyrics = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Back")
                Text("Now Playing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showLyrics.toggle()
                } label: {
                    Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(showLyrics ? .accentColor : .secondary)
                .help(showLyrics ? "Hide lyrics" : "Show lyrics")
                .accessibilityLabel("Lyrics")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    if let track = playbackEngine.currentTrack {
                        artwork(track)
                        Text(track.title)
                            .font(.system(size: 20, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text(track.artist)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.top, 60)
                        Text("Nothing playing")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    if showLyrics {
                        lyricsBlock
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func artwork(_ track: Track) -> some View {
        Group {
            if let data = track.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 260, height: 260)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    /// Mirrors `PopoverView.lyricsContent`'s branch order, scaled up.
    @ViewBuilder private var lyricsBlock: some View {
        if playbackEngine.currentTrack == nil {
            EmptyView()
        } else if lyricsService.isUsingModelFallback {
            VStack(spacing: 12) {
                ProgressView()
                Text("Using LLM fallback to identify the original song…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 40)
        } else if lyricsService.isFetching {
            ProgressView()
                .padding(.vertical, 40)
        } else if let plainLyrics = lyricsService.plainLyrics, !plainLyrics.isEmpty {
            ScrollView {
                Text(plainLyrics)
                    .font(.system(size: 15, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(4)
            }
            .frame(maxHeight: 320)
        } else if lyricsService.lyricLines.isEmpty {
            Text("Lyrics not found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.vertical, 40)
        } else {
            syncedLyrics
        }
    }

    private var syncedLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4 * 1.3) {
                    ForEach(Array(lyricsService.lyricLines.enumerated()), id: \.offset) { index, line in
                        LyricRow(
                            line: line,
                            isActive: lyricsService.currentLineIndex == index,
                            scale: 1.3
                        )
                        .id(index)
                        .onTapGesture {
                            playbackEngine.seek(to: line.timestamp)
                        }
                    }
                }
                .padding(.horizontal, 8 * 1.3)
                .padding(.vertical, 6 * 1.3)
            }
            .onReceive(lyricsService.$currentLineIndex) { newIndex in
                guard let newIndex else { return }
                DispatchQueue.main.async {
                    if reduceMotion {
                        proxy.scrollTo(newIndex, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}
