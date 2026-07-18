#!/bin/bash
set -e

echo "🚀 Starting compilation for Verse Bar..."

# 1. Clean previous builds
rm -rf "Verse Bar.app"
rm -f VerseBar

# 2. Create the App Bundle directory structure
echo "📂 Creating App Bundle structure..."
mkdir -p "Verse Bar.app/Contents/MacOS"
mkdir -p "Verse Bar.app/Contents/Resources"

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
    -o "Verse Bar.app/Contents/MacOS/VerseBar" \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/Models/Track.swift \
    Sources/Models/LyricLine.swift \
    Sources/Models/AppSettings.swift \
    Sources/Services/PlaybackEngine.swift \
    Sources/Services/DiscordPresenceService.swift \
    Sources/Services/NowPlayingService.swift \
    Sources/Services/LyricsService.swift \
    Sources/Services/LyricsMetadataCache.swift \
    Sources/Services/UpdateChecker.swift \
    Sources/UI/Components/GlassmorphicView.swift \
    Sources/UI/Components/MarqueeText.swift \
    Sources/UI/Components/LyricRow.swift \
    Sources/UI/PopoverView.swift \
    Sources/UI/SettingsView.swift \
    Sources/UI/StatusItemManager.swift \
    Sources/UI/TouchBarController.swift \
    Sources/UI/NotchIslandView.swift \
    Sources/UI/NotchIslandController.swift \
    Sources/UI/OnboardingView.swift \
    Sources/UI/OnboardingController.swift \
    Sources/Utilities/AppleScriptRunner.swift \
    Sources/Utilities/Logger.swift \
    Sources/Utilities/MediaKeys.swift \
    Sources/Utilities/PermissionHelper.swift

# 5. Package plist info metadata
echo "📝 Copying Info.plist metadata..."
cp Resources/Info.plist "Verse Bar.app/Contents/Info.plist"

# 5b. Copy the MediaRemote helper script — runs under /usr/bin/swift so the
#     Apple signature satisfies macOS 15.4+ Now Playing restrictions.
cp Resources/now_playing_helper.swift "Verse Bar.app/Contents/Resources/now_playing_helper.swift"

# 6. Verify and finish
if [ -f "Verse Bar.app/Contents/MacOS/VerseBar" ]; then
    echo "🎉 SUCCESS: 'Verse Bar.app' compiled successfully!"
    echo "📍 Output location: $(pwd)/Verse Bar.app"
    echo "🚀 Run the app by executing: open 'Verse Bar.app'"
else
    echo "❌ ERROR: Compilation finished but binary was not found!"
    exit 1
fi
