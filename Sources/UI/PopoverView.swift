import SwiftUI

struct PopoverView: View {
    @ObservedObject private var playbackEngine = PlaybackEngine.shared
    @ObservedObject private var lyricsService = LyricsService.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingManualSearch = false

    var body: some View {
        ZStack {
            GlassmorphicView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                .edgesIgnoringSafeArea(.all)

            if settings.zenMode {
                zenContent
            } else {
                normalContent
            }
        }
        .frame(
            minWidth: settings.zenMode ? 280 : 320,
            idealWidth: settings.zenMode ? 300 : 320,
            minHeight: settings.zenMode ? 140 : 420,
            idealHeight: settings.zenMode ? 180 : 420
        )
        .sheet(isPresented: $showingManualSearch) {
            ManualLyricsSearchView(
                initialQuery: [playbackEngine.currentTrack?.title, playbackEngine.currentTrack?.artist]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }
    }

    private var zenContent: some View {
        GeometryReader { geometry in
            let scale = min(2.4, max(0.8, min(
                geometry.size.width / 300,
                geometry.size.height / 180
            )))

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    pinButton
                    modeButton
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                lyricsContent(scale: scale)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var normalContent: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Verse Bar")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer()

                pinButton
                modeButton

                Button(action: openSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Preferences")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if let track = playbackEngine.currentTrack {
                trackPanel(track)
            }

            lyricsContent()
                .frame(maxHeight: .infinity)

            if let track = playbackEngine.currentTrack,
               lyricsService.plainLyrics == nil,
               !lyricsService.lyricLines.isEmpty {
                syncControls(for: track)
            }
        }
        .padding(.bottom, 12)
    }

    private var pinButton: some View {
        Button {
            settings.pinPopover.toggle()
        } label: {
            Image(systemName: settings.pinPopover ? "pin.fill" : "pin")
        }
        .buttonStyle(.plain)
        .foregroundColor(settings.pinPopover ? .accentColor : .secondary)
        .help(settings.pinPopover ? "Unpin popover" : "Pin popover")
    }

    private var modeButton: some View {
        Button {
            settings.zenMode.toggle()
        } label: {
            Image(systemName: settings.zenMode
                ? "arrow.up.left.and.arrow.down.right"
                : "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(settings.zenMode ? "Switch to Normal Mode" : "Switch to Zen Mode")
    }

    private func trackPanel(_ track: Track) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if let data = track.artworkData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "music.note")
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 26) {
                mediaButton("backward.fill", action: playbackEngine.previousTrack)
                mediaButton(
                    track.isPaused ? "play.fill" : "pause.fill",
                    color: .accentColor,
                    action: playbackEngine.togglePlayPause
                )
                mediaButton("forward.fill", action: playbackEngine.nextTrack)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05).cornerRadius(12))
        .padding(.horizontal, 16)
    }

    private func mediaButton(
        _ systemName: String,
        color: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(color)
    }

    @ViewBuilder
    private func lyricsContent(scale: CGFloat = 1) -> some View {
        if playbackEngine.currentTrack == nil {
            statusText("Play music to see lyrics", scale: scale)
        } else if lyricsService.isFetching {
            ProgressView()
                .controlSize(scale >= 1.5 ? .regular : .small)
        } else if let plainLyrics = lyricsService.plainLyrics, !plainLyrics.isEmpty {
            ScrollView {
                Text(plainLyrics)
                    .font(.system(size: 15 * scale, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(14 * scale)
            }
        } else if lyricsService.lyricLines.isEmpty {
            lyricsFailureContent(scale: scale)
        } else {
            syncedLyrics(scale: scale)
        }
    }

    private func syncedLyrics(scale: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4 * scale) {
                    ForEach(Array(lyricsService.lyricLines.enumerated()), id: \.offset) { index, line in
                        LyricRow(
                            line: line,
                            isActive: lyricsService.currentLineIndex == index,
                            scale: scale
                        )
                        .id(index)
                        .onTapGesture {
                            playbackEngine.seek(to: line.timestamp)
                        }
                    }
                }
                .padding(10 * scale)
            }
            .onChange(of: lyricsService.currentLineIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                guard let index = lyricsService.currentLineIndex else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func syncControls(for track: Track) -> some View {
        let offset = settings.manualSyncOffset(for: track)

        return HStack(spacing: 8) {
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
                settings.setManualSyncOffset(0.0, for: track)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
    }

    private func lyricsFailureContent(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            statusText(lyricsStatusMessage, scale: scale)

            if canSearchManually {
                Button("Search lyrics manually") {
                    showingManualSearch = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(scale >= 1.5 ? .regular : .small)
            }
        }
    }

    private var canSearchManually: Bool {
        switch lyricsService.status {
        case .notFound, .error:
            return true
        default:
            return false
        }
    }

    private func statusText(_ message: String, scale: CGFloat) -> some View {
        Text(message)
            .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(20 * scale)
    }

    private var lyricsStatusMessage: String {
        switch lyricsService.status {
        case .notFound:
            return "Lyrics not found"
        case .unavailableOffline:
            return "Lyrics unavailable offline"
        case .error:
            return "Couldn't load lyrics"
        default:
            return "No lyrics found"
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Notification.Name("ShowSettingsWindow"), object: nil)
    }
}


private struct ManualLyricsSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lyricsService = LyricsService.shared

    let initialQuery: String

    @State private var query = ""
    @State private var results: [LRCLIBResponse] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find lyrics")
                .font(.system(size: 16, weight: .bold, design: .rounded))

            HStack {
                TextField("Song title or artist", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)

                Button("Search", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }

            if isSearching {
                Spacer()
                ProgressView("Searching LRCLIB…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let message {
                Spacer()
                Text(message)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.trackName ?? "Unknown title")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(result.artistName ?? "Unknown artist")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                if let albumName = result.albumName, !albumName.isEmpty {
                                    Text(albumName)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button("Use") {
                                lyricsService.useSearchResult(result)
                                dismiss()
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(width: 440, height: 360)
        .onAppear {
            query = initialQuery
            search()
        }
    }

    private func search() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }

        isSearching = true
        message = nil
        lyricsService.searchLyrics(matching: query) { result in
            isSearching = false
            switch result {
            case .success(let matches):
                results = matches.filter {
                    !($0.syncedLyrics?.isEmpty ?? true) || !($0.plainLyrics?.isEmpty ?? true)
                }
                message = results.isEmpty ? "No lyrics found. Try a different title or artist." : nil
            case .failure:
                results = []
                message = "Search failed. Check your connection and try again."
            }
        }
    }
}
