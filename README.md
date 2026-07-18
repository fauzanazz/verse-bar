# Verse Bar

A macOS menu bar app that shows **synced lyrics** for whatever you're playing on **YouTube / YouTube Music** — in the menu bar, a glassmorphic popover, the **Touch Bar**, and a Dynamic-Island-style **Music Island** under the notch.

> Fork of [alvinindra/verse-bar](https://github.com/alvinindra/verse-bar) with Discord Rich Presence, smarter lyric fallbacks, per-track sync, and more (see below).

Lyrics by [LRCLIB](https://lrclib.net); playback detected via the macOS Now Playing system (MediaRemote), so it works with any browser that supports the Media Session API (Safari, Chrome, Arc, Dia, Brave, Vivaldi, Edge, …) and the YouTube Music Desktop App.

## Features

- Real-time synced lyrics in the menu bar, popover, Touch Bar, and Music Island
- **Zen Mode** — lyrics-only menu bar display (on by default)
- **Romanization** for Korean / Japanese / Chinese lyrics (shown under the original line)
- Album art from the Now Playing source
- **Per-track manual sync offset** (±0.5 s), remembered per song
- Local lyric cache + offline mode
- Guided first-run setup for permissions
- Native track-change notifications

### New in this fork

- **Discord Rich Presence** — shows the current track (with YouTube artwork and a "Listen on YouTube Music" button) on your Discord profile. Opt-in: **Preferences → Show current track on Discord**. Requires the Discord desktop app.
- **Smarter lyric fallbacks** — when LRCLIB has no exact match, the app tries a title-only search, then a cover-song query, and finally (optionally) asks a local [Ollama](https://ollama.com) instance (`127.0.0.1:11434`) to extract the original song metadata from noisy cover-video titles. Results are cached, and you can **manually pick the right lyrics**, which is remembered per track.
- **Per-track sync offsets** instead of one global offset
- **In-app update checker**
- Compact, responsive lyrics popover
- Playback detection focused on YouTube / YouTube Music sources

## Install

Requires macOS 14+.

```bash
git clone https://github.com/fauzanazz/verse-bar.git
cd verse-bar
./build.sh
open "Verse Bar.app"
```

Move the app to `/Applications` so macOS keeps its permissions.

**"Verse Bar was blocked" warning?** The app is ad-hoc signed (not notarized). One-time fix:

```bash
xattr -dr com.apple.quarantine "/Applications/Verse Bar.app"
```

(or **System Settings → Privacy & Security → Open Anyway**.)

## First run

The guided setup window walks you through install location, Automation, and Notification permissions. Then play something on `music.youtube.com` — the lyric appears in the menu bar within ~1.5 s. Re-run it anytime from **Preferences → Re-run Setup Guide**.

Using the YouTube Music Desktop App? Enable its **Companion Server** on port `9863` — no AppleScript permission needed.

### Touch Bar & Music Island

- Open the popover to show the lyric + media controls on the Touch Bar; **pin** the popover to keep them visible across app switches.
- Enable the Music Island under **Preferences → Show Music Island**. Hover the pill to expand it for track info and controls.

## Settings

Right-click the menu bar icon → **Preferences…**: Zen Mode, title/artist/lyric display, Music Island, romanization, Discord presence, per-browser fallbacks, launch at login.

## Development

Build, architecture, testing, and release docs live in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Credits

- Fork of [alvinindra/verse-bar](https://github.com/alvinindra/verse-bar)
- Lyrics by [LRCLIB](https://lrclib.net)
- Inspired by [Lyricfier](https://github.com/emilioastarita/lyricfier) and [SpotMenu](https://github.com/kmikiy/SpotMenu)

## License

MIT — see [LICENSE](LICENSE).
