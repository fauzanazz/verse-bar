import SwiftUI

/// SwiftUI pill view for the Music Island. Renders a black rounded-rectangle
/// "island" that visually wraps the notch on notched MacBooks. The compact
/// state shows just the current synced lyric; hovering expands the pill to
/// reveal track info, transport controls, and the lyric line.
struct NotchIslandView: View {
    @ObservedObject var playbackEngine = PlaybackEngine.shared
    @ObservedObject var lyricsService = LyricsService.shared
    @ObservedObject var viewModel: NotchIslandController.ViewModel

    /// Width carved out by the physical notch (used to keep content clear of it).
    let notchWidth: CGFloat
    /// Vertical inset reserved for the notch at the top of the pill.
    let notchHeight: CGFloat
    /// Called when the pointer enters or leaves the pill, so the host panel
    /// can resize between compact and expanded layouts.
    var onHoverChange: (Bool) -> Void = { _ in }

    @ObservedObject private var settings = AppSettings.shared

    private var isExpanded: Bool { viewModel.isExpanded }

    private var currentLyric: String? {
        guard !lyricsService.lyricLines.isEmpty,
              let idx = lyricsService.currentLineIndex,
              idx >= 0, idx < lyricsService.lyricLines.count else {
            return nil
        }
        let line = lyricsService.lyricLines[idx]
        let text: String
        if settings.showRomanization, let romanized = line.romanized {
            text = romanized
        } else {
            text = line.text
        }
        return text.isEmpty ? nil : text
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)

            VStack(spacing: 0) {
                // Reserve space for the physical notch at the top center.
                Color.clear.frame(height: max(notchHeight - 2, 0))

                Group {
                    if isExpanded {
                        expandedContent
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    } else {
                        compactContent
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            NotificationCenter.default.post(name: Notification.Name("ShowPlayerStudioSoundCapsule"), object: nil)
        }
        .onHover { inside in
            onHoverChange(inside)
        }
    }

    // MARK: - Compact

    private var compactContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 18)

            Text(currentLyric ?? trackSummary ?? "Player Studio")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 22)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    if let data = playbackEngine.currentTrack?.artworkData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playbackEngine.currentTrack?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(playbackEngine.currentTrack?.artist ?? "")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    controlButton(symbol: "backward.fill", size: 13) {
                        playbackEngine.previousTrack()
                    }
                    controlButton(symbol: playPauseSymbol(), size: 17) {
                        playbackEngine.togglePlayPause()
                    }
                    controlButton(symbol: "forward.fill", size: 13) {
                        playbackEngine.nextTrack()
                    }
                }
            }

            if let lyric = currentLyric {
                Text(lyric)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func controlButton(symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }

    private func playPauseSymbol() -> String {
        (playbackEngine.currentTrack?.isPaused ?? true) ? "play.fill" : "pause.fill"
    }

    private var trackSummary: String? {
        guard let track = playbackEngine.currentTrack else { return nil }
        if track.artist.isEmpty { return track.title }
        return "\(track.title) — \(track.artist)"
    }
}
