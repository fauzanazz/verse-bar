import SwiftUI

struct PopoverView: View {
    @ObservedObject var playbackEngine = PlaybackEngine.shared
    @ObservedObject var lyricsService = LyricsService.shared
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        ZStack {
            // Glassmorphic background
            GlassmorphicView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 12) {
                // Header bar
                HStack(spacing: 14) {
                    Text("Verse Bar")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: { settings.pinPopover.toggle() }) {
                        Image(systemName: settings.pinPopover ? "pin.fill" : "pin")
                            .font(.system(size: 12))
                            .rotationEffect(.degrees(settings.pinPopover ? 0 : 30))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(settings.pinPopover ? .accentColor : .secondary)
                    .help(settings.pinPopover
                          ? "Unpin — popover dismisses when clicking other apps"
                          : "Pin — keep popover (and Touch Bar lyric) visible across apps")

                    Button(action: openSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Preferences")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                // Track Info Panel
                if let track = playbackEngine.currentTrack {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            // Cover art — real artwork from MediaRemote when
                            // available, placeholder otherwise.
                            ZStack {
                                if let data = track.artworkData, let nsImage = NSImage(data: data) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "music.note")
                                        .font(.system(size: 20))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Text(track.artist)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        
                        // Media Controls
                        HStack(spacing: 24) {
                            Button(action: { triggerPlayerAction(.previous) }) {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.primary)
                            
                            Button(action: { triggerPlayerAction(.togglePlayPause) }) {
                                Image(systemName: track.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 18, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            
                            Button(action: { triggerPlayerAction(.next) }) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.primary)
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.05).cornerRadius(12))
                    .padding(.horizontal, 16)
                    
                    // Synced Lyrics View
                    VStack {
                        if lyricsService.isFetching {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Searching lyrics...")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxHeight: .infinity)
                        } else if let plainLyrics = lyricsService.plainLyrics, !plainLyrics.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Full lyrics (unsynced)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                                ScrollView {
                                    Text(plainLyrics)
                                        .font(.system(size: 13, design: .rounded))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                        .textSelection(.enabled)
                                        .padding(.vertical, 20)
                                }
                            }
                        } else if lyricsService.lyricLines.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: lyricsStatusIcon)
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                                Text(lyricsStatusMessage)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxHeight: .infinity)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView(showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(Array(lyricsService.lyricLines.enumerated()), id: \.offset) { index, line in
                                            LyricRow(line: line, isActive: lyricsService.currentLineIndex == index)
                                                .id(index)
                                                .onTapGesture {
                                                    seekPlayer(to: line.timestamp)
                                                }
                                        }
                                    }
                                    .padding(.vertical, 20)
                                }
                                .onChange(of: lyricsService.currentLineIndex) { _, newIndex in
                                    if let idx = newIndex {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                            proxy.scrollTo(idx, anchor: .center)
                                        }
                                    }
                                }
                                .onAppear {
                                    if let idx = lyricsService.currentLineIndex {
                                        proxy.scrollTo(idx, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                    .padding(.horizontal, 16)
                    
                    Divider()
                        .padding(.horizontal, 16)
                    
                    // Timing offset controls & source info
                    VStack(spacing: 6) {
                        if lyricsService.plainLyrics == nil {
                            HStack {
                                Text("Sync Offset:")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Button(action: { settings.manualSyncOffset -= 0.5 }) {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                
                                Text(String(format: "%+.1fs", settings.manualSyncOffset))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(width: 48)
                                
                                Button(action: { settings.manualSyncOffset += 0.5 }) {
                                    Image(systemName: "plus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                
                                Button("Reset") {
                                    settings.manualSyncOffset = 0.0
                                }
                                .font(.system(size: 10, weight: .bold))
                                .buttonStyle(.borderless)
                                .padding(.leading, 6)
                            }
                        }
                        
                        HStack {
                            Text(lyricsService.plainLyrics == nil ? "Lyrics via LRCLIB" : "Full lyrics via LRCLIB")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.7))
                            Spacer()
                            if lyricsService.offlineMode {
                                Text("Offline Mode")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    
                } else {
                    // Empty/Fallback state when nothing is playing
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.04))
                                .frame(width: 72, height: 72)
                            Image(systemName: "music.note.house.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(spacing: 4) {
                            Text("YouTube Music Inactive")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text("Play a track in Safari, Chrome, Arc, or YouTube Music Desktop to sync lyrics.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        
                        Button("Open YouTube Music") {
                            if let url = URL(string: "https://music.youtube.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 11, weight: .bold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(height: 380)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(width: 320)
    }
    
    /// Message shown in the popup's lyrics area when there are no synced lines.
    /// This is the *only* place "Synced lyrics not found" appears — the menu
    /// bar just shows its icon.
    private var lyricsStatusMessage: String {
        switch lyricsService.status {
        case .notFound:          return "Synced lyrics not found"
        case .unavailableOffline: return "Lyrics unavailable offline"
        case .error:             return "Couldn't load lyrics"
        default:                 return "No lyrics found"
        }
    }

    private var lyricsStatusIcon: String {
        switch lyricsService.status {
        case .unavailableOffline: return "wifi.slash"
        case .error:             return "exclamationmark.triangle.fill"
        default:                 return "quote.bubble.fill"
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Post a notification to show the settings window
        NotificationCenter.default.post(name: Notification.Name("ShowSettingsWindow"), object: nil)
    }
    
    enum PlayerAction {
        case togglePlayPause
        case next
        case previous
    }

    private func triggerPlayerAction(_ action: PlayerAction) {
        switch action {
        case .togglePlayPause: playbackEngine.togglePlayPause()
        case .next:            playbackEngine.nextTrack()
        case .previous:        playbackEngine.previousTrack()
        }
    }

    private func seekPlayer(to seconds: TimeInterval) {
        playbackEngine.seek(to: seconds)
    }
}

