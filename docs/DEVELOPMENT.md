# Development

## Build

Two ways to build:

```bash
./build.sh            # produces "Player Studio.app" via swiftc — no Xcode project needed
swift build           # SwiftPM (Package.swift), useful for iteration
swift test            # runs the test suite (Tests/)
```

Requires the Swift toolchain (`swiftc`, ships with Xcode Command Line Tools) and macOS 14+.

## Project layout

```
Sources/
├── AppDelegate.swift
├── main.swift
├── Models/         # Track, LyricLine, AppSettings
├── Services/       # PlaybackEngine, LyricsService, LyricsMetadataCache,
│                   # NowPlayingService, DiscordPresenceService, UpdateChecker,
│                   # YouTubeDownloadService
├── UI/             # StatusItemManager, PopoverView, SettingsView, TouchBarController,
│                   # NotchIslandController/View, OnboardingController/View, Components/
└── Utilities/      # AppleScriptRunner, Logger, MediaKeys, PermissionHelper
Resources/
├── Info.plist
└── now_playing_helper.swift   # Apple-signed swift helper invoked by NowPlayingService
Tests/              # DiscordPresenceServiceTests
build.sh
Package.swift
```

## How it works

- `NowPlayingService` spawns a small Apple-signed helper script under `/usr/bin/swift` that streams the system Now Playing state (title, artist, elapsed, duration, album artwork) as JSON lines. The helper signature is required because macOS 15.4+ restricts `MRMediaRemoteGetNowPlayingInfo` to Apple-signed callers.
- `PlaybackEngine` consumes that stream every 1.5 s, restricted to YouTube / YouTube Music sources. Per-browser AppleScript paths exist as a fallback but are skipped while Now Playing is live — `execute javascript` against suspended tabs can hang.
- `LyricsService` fetch chain:
  1. LRCLIB `/api/get` (exact artist + title + duration match)
  2. LRCLIB `/api/search` (title-only when the artist is generic, e.g. "YouTube Music")
  3. Cover-song query built from the video title
  4. **Ollama fallback** — POSTs to `http://127.0.0.1:11434/api/chat` (`gpt-oss:120b-cloud`, JSON format, temperature 0) to extract original `track`/`artist` from noisy cover-video metadata, then re-queries LRCLIB. Silently skipped if Ollama isn't running.
- `LyricsMetadataCache` persists normalized metadata and the user's **manual lyric selections** (exact + fuzzy lookup), so a chosen match sticks across sessions.
- Each lyric line runs through `CFStringTransform "Any-Latin"` to attach a romanization when CJK characters are detected; results are cached on disk with both original and romanized text (`~/Library/Application Support/com.playerstudio.PlayerStudio/LyricsCache`).
- A 100 ms timer interpolates the active line against playback position plus the per-track manual offset (`AppSettings.manualSyncOffset(for:)`).
- `DiscordPresenceService` speaks the Discord IPC protocol directly over the local Unix socket (no SDK): little-endian length-prefixed frames, handshake, `SET_ACTIVITY` with track info, YouTube thumbnail artwork, and a "Listen on YouTube Music" button. Ping frames are answered with pongs. See `Tests/DiscordPresenceServiceTests.swift` for the codec contract.
- `UpdateChecker` polls the GitHub releases API and compares semver against `CFBundleShortVersionString`, surfacing an "Update available" affordance in the UI.
- `PopoverHostingController` vends an `NSTouchBar` while the popover is on screen: lyric on the left, three media-control buttons on the right.

### Why no always-visible Control Strip icon?

macOS Sequoia (15.x) silently filters third-party tray items registered with `addSystemTrayItem:` + `DFRElementSetControlStripPresenceForIdentifier` unless the binary is Developer-ID signed and notarized. This project ships ad-hoc signed, so the ambient Control Strip path is not viable; the popover **Pin** toggle is the supported workaround.

## Gotchas

- **Periodic timers must live in the smallest view that needs them.** A `Timer.publish` (e.g. the 0.5 s progress ticker) attached to a window-level view re-renders the entire tree every tick — including the `NavigationSplitView` detail. Rows re-render, and any **open SwiftUI `Menu` gets rebuilt and collapses** (submenu triggers visibly vanish under the cursor, "flicker"). Symptom seen: "Add to Album" trigger vanishing on hover in Home but not Library. Fix: extract the ticking UI into its own view that owns the timer and its `@State` (see `SeekBar`), so the tick only re-renders the slider row.

## Releases

Tagged commits on `main` (`v1.x.y`) trigger `.github/workflows/release.yml`, which builds the app, packages it, and attaches the archive to a GitHub Release:

```bash
git tag v1.2.0
git push origin v1.2.0
```

## Contributing

Issues and pull requests welcome. Keep PRs focused — one fix or feature per PR. Run `./build.sh` (and `swift test`) and exercise the app before requesting review.
