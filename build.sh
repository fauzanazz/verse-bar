#!/bin/bash
set -e

echo "🚀 Starting compilation for Player Studio..."

# 1. Clean previous builds
rm -rf "Player Studio.app"
rm -f PlayerStudio

# 2. Create the App Bundle directory structure
echo "📂 Creating App Bundle structure..."
mkdir -p "Player Studio.app/Contents/MacOS"
mkdir -p "Player Studio.app/Contents/Resources"

# 3. Resolve macOS SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
echo "📦 Using macOS SDK at: $SDK_PATH"

# 4. Compile Swift files
echo "🛠️ Compiling Swift sources..."
swiftc -sdk "$SDK_PATH" \
    -Onone \
    -DDEBUG \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -framework AVFoundation \
    -framework MediaPlayer \
    -o "Player Studio.app/Contents/MacOS/PlayerStudio" \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/Models/Track.swift \
    Sources/Models/LyricLine.swift \
    Sources/Models/AppSettings.swift \
    Sources/Models/LibraryTrack.swift \
    Sources/Models/PlayQueue.swift \
    Sources/Models/Album.swift \
    Sources/Models/ListeningCapsule.swift \
    Sources/Services/PlaybackEngine.swift \
    Sources/Services/DiscordPresenceService.swift \
    Sources/Services/NowPlayingService.swift \
    Sources/Services/LyricsService.swift \
    Sources/Services/LyricsMetadataCache.swift \
    Sources/Services/ListeningStatsService.swift \
    Sources/Services/UpdateChecker.swift \
    Sources/Services/YouTubeDownloadService.swift \
    Sources/Services/YouTubeSearchService.swift \
    Sources/Services/YouTubeStreamService.swift \
    Sources/Services/LibraryService.swift \
    Sources/Services/AlbumService.swift \
    Sources/Services/AppleLyricsService.swift \
    Sources/Services/AudioPlayerService.swift \
    Sources/Services/VocalSeparationService.swift \
    Sources/UI/Components/GlassmorphicView.swift \
    Sources/UI/Components/MarqueeText.swift \
    Sources/UI/Components/LyricRow.swift \
    Sources/UI/Components/TrackRow.swift \
    Sources/UI/PopoverView.swift \
    Sources/UI/SettingsView.swift \
    Sources/UI/SoundCapsuleView.swift \
    Sources/UI/SoundCapsuleDetailView.swift \
    Sources/UI/StatusItemManager.swift \
    Sources/UI/TouchBarController.swift \
    Sources/UI/NotchIslandView.swift \
    Sources/UI/NotchIslandController.swift \
    Sources/UI/OnboardingView.swift \
    Sources/UI/OnboardingController.swift \
    Sources/UI/MainWindowController.swift \
    Sources/UI/MainWindowView.swift \
    Sources/UI/HomeView.swift \
    Sources/UI/LibraryView.swift \
    Sources/UI/AlbumsView.swift \
    Sources/UI/AlbumDetailView.swift \
    Sources/UI/BrowseView.swift \
    Sources/UI/NowPlayingView.swift \
    Sources/Utilities/AppleScriptRunner.swift \
    Sources/Utilities/Logger.swift \
    Sources/Utilities/MediaKeys.swift \
    Sources/Utilities/PermissionHelper.swift

# 5. Package plist info metadata
echo "📝 Copying Info.plist metadata..."
cp Resources/Info.plist "Player Studio.app/Contents/Info.plist"

# 5b. Copy the MediaRemote helper script — runs under /usr/bin/swift so the
#     Apple signature satisfies macOS 15.4+ Now Playing restrictions.
cp Resources/now_playing_helper.swift "Player Studio.app/Contents/Resources/now_playing_helper.swift"

# 5c. App icon (Dock/Finder) + menu bar glyph derived from the logo.
cp Resources/PlayerStudio.icns "Player Studio.app/Contents/Resources/PlayerStudio.icns"
cp Resources/MenuBarIcon.png "Player Studio.app/Contents/Resources/MenuBarIcon.png"

# 5d. Bundle yt-dlp + ffmpeg so downloads work without any Homebrew install.
#     Cached in .build/binaries (gitignored); set BIN_FORCE=1 to refresh.
BIN_DIR=".build/binaries"
mkdir -p "$BIN_DIR"
fetch_binary() {
    local name="$1" url="$2" out="$3"
    if [ ! -f "$out" ] || [ -n "$BIN_FORCE" ]; then
        echo "⬇️  Downloading $name..."
        curl -L --fail --silent --show-error "$url" -o "$out"
        chmod +x "$out"
    fi
}
fetch_binary "yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" "$BIN_DIR/yt-dlp"
fetch_binary "ffmpeg" "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-arm64" "$BIN_DIR/ffmpeg"
cp "$BIN_DIR/yt-dlp" "$BIN_DIR/ffmpeg" "Player Studio.app/Contents/Resources/"

# 6. Verify and finish
if [ -f "Player Studio.app/Contents/MacOS/PlayerStudio" ]; then
    echo "🎉 SUCCESS: 'Player Studio.app' compiled successfully!"
    echo "📍 Output location: $(pwd)/Player Studio.app"
    echo "🚀 Run the app by executing: open 'Player Studio.app'"
else
    echo "❌ ERROR: Compilation finished but binary was not found!"
    exit 1
fi
