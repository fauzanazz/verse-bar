import SwiftUI

/// One wrapping `Text` with per-word karaoke coloring. The active word fills
/// per character: `activeFraction` in [0, 1] lights up that fraction of its
/// glyphs.
func karaokeText(
    words: [LyricWord],
    activeIndex: Int?,
    activeFraction: Double,
    romanized: Bool,
    sung: Color,
    upcoming: Color,
    emphasizeCurrent: Bool
) -> Text {
    var result = Text("")
    for (index, word) in words.enumerated() {
        let display = romanized ? (word.romanized ?? word.text) : word.text
        let prefix = (index == 0 || words[index - 1].joinsNext) ? "" : " "
        if index < (activeIndex ?? -1) {
            result = result + Text(prefix + display).foregroundColor(sung)
        } else if activeIndex == nil || index > activeIndex! {
            result = result + Text(prefix + display).foregroundColor(upcoming)
        } else {
            let chars = Array(display)
            let lit = min(chars.count, Int((Double(chars.count) * activeFraction).rounded(.down)))
            var sungRun = Text(prefix + String(chars.prefix(lit))).foregroundColor(sung)
            var upcomingRun = Text(String(chars.dropFirst(lit))).foregroundColor(upcoming)
            if emphasizeCurrent {
                sungRun = sungRun.fontWeight(.bold)
                upcomingRun = upcomingRun.fontWeight(.bold)
            }
            result = result + sungRun + upcomingRun
        }
    }
    return result
}

struct LyricSyncControls: View {
    let track: Track
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let offset = settings.manualSyncOffset(for: track)

        HStack(spacing: 8) {
            Text("Sync")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)

            Spacer()

            Button {
                settings.setManualSyncOffset(offset - 0.5, for: track)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)

            Text(String(format: "%+.1fs", offset))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 48)

            Button {
                settings.setManualSyncOffset(offset + 0.5, for: track)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.plain)

            Button("Reset") {
                settings.setManualSyncOffset(0, for: track)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
    }
}

struct LyricRow: View {
    let line: LyricLine
    let isActive: Bool
    let activeWordIndex: Int?
    let activeWordFraction: Double
    var scale: CGFloat = 1
    @ObservedObject private var settings = AppSettings.shared

    private var hasRomanized: Bool {
        settings.showRomanization && line.romanized != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasRomanized ? 2 : 0) {
            if isActive && !line.words.isEmpty {
                karaokeText(
                    words: line.words,
                    activeIndex: activeWordIndex,
                    activeFraction: activeWordFraction,
                    romanized: false,
                    sung: .accentColor,
                    upcoming: .primary.opacity(0.45),
                    emphasizeCurrent: true
                )
                .font(.system(size: 16 * scale, weight: .medium, design: .rounded))
            } else {
                Text(line.text)
                    .font(.system(size: (isActive ? 16 : 14) * scale, weight: .medium, design: .rounded))
                    .foregroundColor(isActive ? .accentColor : .primary)
                    .opacity(isActive ? 1.0 : 0.5)
            }

            if hasRomanized, let romanized = line.romanized {
                if isActive && !line.words.isEmpty {
                    karaokeText(
                        words: line.words,
                        activeIndex: activeWordIndex,
                        activeFraction: activeWordFraction,
                        romanized: true,
                        sung: .accentColor.opacity(0.85),
                        upcoming: .secondary,
                        emphasizeCurrent: false
                    )
                    .font(.system(size: 12 * scale, weight: .regular, design: .rounded))
                } else {
                    Text(romanized)
                        .font(.system(size: (isActive ? 12 : 11) * scale, weight: .regular, design: .rounded))
                        .foregroundColor(isActive ? .accentColor.opacity(0.85) : .secondary)
                        .opacity(isActive ? 0.9 : 0.45)
                }
            }
        }
        .padding(.vertical, (hasRomanized ? 6 : 2) * scale)
        .padding(.horizontal, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive ?
            Color.accentColor.opacity(0.12)
                .cornerRadius(8)
            : Color.clear.cornerRadius(0)
        )
        .scaleEffect(isActive ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
    }
}

/// Synced lyric list with active-line auto-scroll. Shared by the popover and
/// the Now Playing pane so the scroll behaviour only exists once.
struct SyncedLyricsView: View {
    var scale: CGFloat = 1

    @ObservedObject private var lyricsService = LyricsService.shared
    @ObservedObject private var playbackEngine = PlaybackEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // ponytail: plain VStack, not Lazy — scrollTo needs the target
                // row realized, and lyric rows are just Text.
                VStack(alignment: .leading, spacing: 4 * scale) {
                    ForEach(Array(lyricsService.lyricLines.enumerated()), id: \.offset) { index, line in
                        LyricRow(
                            line: line,
                            isActive: lyricsService.currentLineIndex == index,
                            activeWordIndex: lyricsService.currentWordIndex,
                            activeWordFraction: lyricsService.currentWordFraction,
                            scale: scale
                        )
                        .id(index)
                        .onTapGesture {
                            playbackEngine.seek(to: line.timestamp)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 6 * scale)
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
