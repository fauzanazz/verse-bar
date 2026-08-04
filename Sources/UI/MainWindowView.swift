import Combine
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case home, browse, library, capsule, settings
    var id: String { rawValue }
}

/// External navigation for the main window (status menu, notch island).
final class MainWindowRouter: ObservableObject {
    static let shared = MainWindowRouter()
    @Published var section: MainSection = .home
    @Published var showNowPlaying = false
    private init() {}
}

/// `mm:ss`, matching the popover's duration formatting.
func timeString(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let seconds = Int(t.rounded())
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

/// Window shell: sidebar + content + bottom transport bar.
struct MainWindowView: View {
    @ObservedObject private var router = MainWindowRouter.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var sliderValue: Double = 0
    @State private var isScrubbing = false
    /// Karaoke refusals are too long for the crowded transport bar; they pop
    /// over the mic button instead of being truncated inline.
    @State private var showKaraokeError = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: $router.section) {
                    Label("Home", systemImage: "house.fill").tag(MainSection.home)
                    Label("Browse", systemImage: "square.grid.2x2.fill").tag(MainSection.browse)
                    Label("Library", systemImage: "music.note.list").tag(MainSection.library)
                    Divider()
                    Label("Sound Capsule", systemImage: "chart.bar.fill").tag(MainSection.capsule)
                    Label("Preferences", systemImage: "gearshape.fill").tag(MainSection.settings)
                }
                .listStyle(.sidebar)
                .onChange(of: router.section) { _, _ in
                    router.showNowPlaying = false
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                .safeAreaInset(edge: .top) {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.accentColor)
                        Text("Player Studio")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } detail: {
                if router.showNowPlaying {
                    NowPlayingView(onClose: { router.showNowPlaying = false })
                } else {
                    switch router.section {
                    case .home: HomeView(onBrowse: { router.section = .browse })
                    case .browse: BrowseView()
                    case .library: LibraryView()
                    case .capsule: centered(SoundCapsuleView())
                    case .settings: centered(SettingsView())
                    }
                }
            }

            Divider()
            transportBar
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: 14) {
            nowPlayingButton

            VStack(alignment: .leading, spacing: 1) {
                Text(audioPlayer.queue.current?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(audioPlayer.queue.current?.artist ?? "Pilih lagu dari Library untuk mulai memutar")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)

            Spacer()

            HStack(spacing: 12) {
                transportButton("shuffle", isOn: audioPlayer.queue.isShuffled) {
                    audioPlayer.setShuffled(!audioPlayer.queue.isShuffled)
                }
                transportButton("backward.fill") { audioPlayer.previous() }
                Button {
                    audioPlayer.togglePlayPause()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
                .disabled(!hasTrack)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")
                transportButton("forward.fill") { audioPlayer.next() }
                transportButton(audioPlayer.queue.repeatMode == .one ? "repeat.1" : "repeat", isOn: audioPlayer.queue.repeatMode != .off) {
                    audioPlayer.cycleRepeatMode()
                }
            }

            Spacer()

            Text(timeString(audioPlayer.elapsed))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()

            Slider(value: $sliderValue, in: 0...max(duration, 1)) { editing in
                if editing {
                    isScrubbing = true
                } else {
                    isScrubbing = false
                    audioPlayer.seek(to: sliderValue)
                }
            }
            .frame(maxWidth: 280)
            .disabled(!hasTrack)

            Text(timeString(duration))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()

            Spacer()

            karaokeControl

            Button {
                router.showNowPlaying.toggle()
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(router.showNowPlaying ? .accentColor : .secondary)
            .help("Lyrics")
            .accessibilityLabel("Lyrics")

            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Slider(value: $audioPlayer.volume, in: 0...1)
                .frame(width: 90)
        }
        .frame(height: 64)
        .padding(.horizontal, 16)
        .onReceive(ticker) { _ in
            if !isScrubbing { sliderValue = audioPlayer.elapsed }
        }
        // Async failures (demucs exiting mid-run) never pass through the button
        // action, so the popover also follows the state.
        .onChange(of: karaokeFailure) { _, new in showKaraokeError = new != nil }
    }

    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @ObservedObject private var separation = VocalSeparationService.shared

    private var hasTrack: Bool { audioPlayer.queue.current != nil }

    private var duration: TimeInterval {
        audioPlayer.queue.current?.duration ?? 0
    }

    private var nowPlayingButton: some View {
        Button {
            router.showNowPlaying.toggle()
        } label: {
            Group {
                if let track = audioPlayer.queue.current,
                   let image = LibraryService.shared.artwork(for: track) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Now Playing")
    }

    /// Karaoke toggle: mic when idle, live progress while demucs runs (press to
    /// cancel), red mic with the reason when the last attempt for this track failed.
    @ViewBuilder private var karaokeControl: some View {
        if let track = audioPlayer.queue.current, separation.isBusy(with: track) {
            Button { separation.cancel() } label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(separation.progressLabel)
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help("Separating vocals — click to cancel")
            .accessibilityLabel("Cancel karaoke separation")
        } else {
            transportButton("music.mic", isOn: audioPlayer.isKaraoke) {
                audioPlayer.setKaraoke(!audioPlayer.isKaraoke)
                // Re-pressing after the same refusal leaves `state` unchanged,
                // so `onChange` will not fire — reopen it here.
                showKaraokeError = karaokeFailure != nil
            }
            .foregroundColor(karaokeFailure != nil ? .red : (audioPlayer.isKaraoke ? .accentColor : .secondary))
            .help(karaokeFailure
                  ?? (audioPlayer.isKaraokeActive ? "Karaoke: instrumental" : "Karaoke (remove vocals)"))
            .accessibilityLabel("Karaoke")
            .popover(isPresented: $showKaraokeError, arrowEdge: .top) {
                Text(karaokeFailure ?? "")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(14)
            }
        }
    }

    /// Failure message from the last separation attempt for the current track.
    private var karaokeFailure: String? {
        guard case .failed(let trackID, let message) = separation.state,
              trackID == audioPlayer.queue.current?.id else { return nil }
        return message
    }

    private func transportButton(_ systemName: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(isOn ? .accentColor : .secondary)
        .disabled(!hasTrack)
    }

    /// Capsule/settings panes are built for a ~420-560pt column; center them
    /// in the wide detail pane instead of letting them stretch.
    private func centered<Content: View>(_ content: Content) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content.frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
    }
}
