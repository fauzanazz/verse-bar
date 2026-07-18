import Foundation
import AppKit
import Combine
import UserNotifications

struct YouTubeTabCandidate: Equatable {
    let title: String
    let url: URL
}

enum YouTubeTrackMatchState: Equatable {
    case matched
    case titleMismatch
    case noCandidates
}

enum YouTubeArtworkResolver {
    private static let supportedHosts = ["youtube.com", "www.youtube.com", "music.youtube.com"]
    private static let titleSuffixes = [" - YouTube Music", " | YouTube Music", " - YouTube", " | YouTube"]
    private static let videoIDCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    static func candidates(from appleScriptOutput: String) -> [YouTubeTabCandidate] {
        appleScriptOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.components(separatedBy: "|||")
            guard fields.count == 2,
                  let url = URL(string: fields[1]),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return YouTubeTabCandidate(title: fields[0], url: url)
        }
    }

    static func videoID(from watchURL: URL) -> String? {
        guard let components = URLComponents(url: watchURL, resolvingAgainstBaseURL: false),
              supportedHosts.contains(components.host?.lowercased() ?? ""),
              components.path == "/watch",
              let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value,
              videoID.utf8.count == 11,
              videoID.unicodeScalars.allSatisfy(videoIDCharacters.contains)
        else { return nil }
        return videoID
    }

    static func thumbnailURL(from watchURL: URL) -> URL? {
        guard let videoID = videoID(from: watchURL) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    static func trackMatchState(in candidates: [YouTubeTabCandidate], trackTitle: String) -> YouTubeTrackMatchState {
        guard !candidates.isEmpty else { return .noCandidates }
        let trackTitle = normalizedTitle(trackTitle)
        guard !trackTitle.isEmpty else { return .titleMismatch }
        return candidates.contains {
            let tabTitle = normalizedTitle($0.title)
            return !tabTitle.isEmpty
                && (tabTitle.contains(trackTitle) || trackTitle.contains(tabTitle))
        } ? .matched : .titleMismatch
    }

    static func selectThumbnailURL(from candidates: [YouTubeTabCandidate], trackTitle: String) -> URL? {
        let watchCandidates = candidates.compactMap { candidate in
            thumbnailURL(from: candidate.url).map { (candidate, $0) }
        }
        let foldedTrackTitle = normalizedTitle(trackTitle)
        let matches = watchCandidates.filter {
            let foldedTabTitle = normalizedTitle($0.0.title)
            return !foldedTrackTitle.isEmpty
                && (foldedTabTitle.contains(foldedTrackTitle) || foldedTrackTitle.contains(foldedTabTitle))
        }
        if matches.count == 1 {
            return matches[0].1
        }
        return matches.isEmpty && watchCandidates.count == 1 ? watchCandidates[0].1 : nil
    }

    private static func normalizedTitle(_ title: String) -> String {
        var title = title
        if let suffix = titleSuffixes.first(where: { title.hasSuffix($0) }) {
            title.removeLast(suffix.count)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

class PlaybackEngine: ObservableObject {
    static let shared = PlaybackEngine()
    
    @Published var currentTrack: Track?
    
    private var timer: Timer?
    private let settings = AppSettings.shared
    private var isPolling = false
    
    // JavaScript that extracts everything from YTM DOM in one call
    // Uses ONLY single quotes to be safe inside AppleScript double-quoted strings
    // Returns: title|||artist|||currentTime|||duration|||paused
    private static func makeYTMExtractionJS() -> String {
        return """
        (function(){
            var v = document.querySelector('video');
            if (!v) return '';
            var titleEl = document.querySelector('yt-formatted-string.title.style-scope.ytmusic-player-bar')
                       || document.querySelector('.title.style-scope.ytmusic-player-bar')
                       || document.querySelector('ytmusic-player-bar .title');
            var artistEl = document.querySelector('yt-formatted-string.byline.style-scope.ytmusic-player-bar a')
                        || document.querySelector('.byline.style-scope.ytmusic-player-bar a')
                        || document.querySelector('ytmusic-player-bar .byline a')
                        || document.querySelector('yt-formatted-string.byline.style-scope.ytmusic-player-bar')
                        || document.querySelector('.byline.style-scope.ytmusic-player-bar');
            var title = titleEl ? titleEl.textContent.trim() : '';
            var artist = artistEl ? artistEl.textContent.trim() : '';
            if (!title && document.title) {
                var dt = document.title.replace(/ - YouTube Music$/, '').replace(/ [|] YouTube Music$/, '');
                if (dt !== 'YouTube Music' && dt !== 'YouTube') {
                    var parts = dt.split(' - ');
                    if (parts.length >= 2) { title = parts[0].trim(); artist = parts.slice(1).join(' - ').trim(); }
                    else { title = dt.trim(); }
                }
            }
            var ct = v.currentTime || 0;
            var dur = v.duration || 0;
            var paused = v.paused;
            return title + '|||' + artist + '|||' + ct + '|||' + dur + '|||' + paused;
        })()
        """
    }
    
    // Simplified JS for regular YouTube (non-music) pages
    private static func makeYTExtractionJS() -> String {
        return """
        (function(){
            var v = document.querySelector('video');
            if (!v) return '';
            var titleEl = document.querySelector('h1.ytd-watch-metadata yt-formatted-string')
                       || document.querySelector('#info-contents h1 yt-formatted-string')
                       || document.querySelector('h1.title');
            var channelEl = document.querySelector('#owner #channel-name a')
                         || document.querySelector('ytd-channel-name a')
                         || document.querySelector('#upload-info a');
            var title = titleEl ? titleEl.textContent.trim() : '';
            var artist = channelEl ? channelEl.textContent.trim() : '';
            if (!title) {
                var dt = document.title.replace(/ - YouTube$/, '').replace(/ [|] YouTube$/, '');
                if (dt !== 'YouTube') title = dt.trim();
            }
            var ct = v.currentTime || 0;
            var dur = v.duration || 0;
            var paused = v.paused;
            return title + '|||' + artist + '|||' + ct + '|||' + dur + '|||' + paused;
        })()
        """
    }
    
    /// Escape a JavaScript string for embedding inside an AppleScript double-quoted string.
    /// AppleScript only recognizes \" and \\ as escape sequences.
    private static func escapeForAppleScript(_ js: String) -> String {
        return js
            .replacingOccurrences(of: "\\", with: "\\\\")  // Escape backslashes first
            .replacingOccurrences(of: "\"", with: "\\\"")  // Then escape double quotes
    }
    
    private init() {
        // Give the MediaRemote helper a moment to start streaming so the very
        // first poll already has Now Playing data and doesn't fall through to
        // the slower browser-AppleScript path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.startPolling()
        }
    }
    
    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Also trigger first poll immediately
        poll()
        Logger.info("Playback Engine polling started.", category: "playback")
    }
    
    func stopPolling() {
        timer?.invalidate()
        timer = nil
        Logger.info("Playback Engine polling stopped.", category: "playback")
    }
    
    private func isApplicationRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        
        // Skip the per-browser AppleScript fallbacks while the MediaRemote
        // helper is alive — it covers every Media-Session-capable browser
        // (Arc, Dia, Brave, Chrome, Safari, Vivaldi, etc) without scripting
        // each one, and `execute javascript` against suspended tabs can hang
        // the polling loop for minutes.
        let nowPlayingActive = NowPlayingService.shared.isStreaming()
        let sources: [(Bool, String, (@escaping (Bool) -> Void) -> Void)] = [
            (true, "NowPlaying", { self.pollNowPlaying(completion: $0) }),
            (!nowPlayingActive && settings.trackingArc, "Arc", { self.pollArc(completion: $0) }),
            (!nowPlayingActive && settings.trackingChrome, "Chrome", { self.pollChrome(completion: $0) }),
            (!nowPlayingActive && settings.trackingSafari, "Safari", { self.pollSafari(completion: $0) }),
            (settings.trackingYTMDesktop, "YTMDesktop", { self.pollYTMDesktop(completion: $0) })
        ]
        
        func trySource(at index: Int) {
            if index >= sources.count {
                DispatchQueue.main.async {
                    if self.currentTrack != nil {
                        self.currentTrack = nil
                    }
                    self.isPolling = false
                }
                return
            }

            let (enabled, name, pollFunc) = sources[index]
            if enabled {
                pollFunc { [weak self] success in
                    if success {
                        Logger.info("✅ Source \(name): track found", category: "playback")
                        self?.isPolling = false
                    } else {
                        trySource(at: index + 1)
                    }
                }
            } else {
                trySource(at: index + 1)
            }
        }
        
        trySource(at: 0)
    }
    
    // MARK: - System Now Playing (browser-agnostic via MediaRemote)
    private func pollNowPlaying(completion: @escaping (Bool) -> Void) {
        guard let info = NowPlayingService.shared.currentInfo() else {
            completion(false)
            return
        }

        // MediaRemote reports every media source; accept supported desktop
        // players directly and verify browser playback separately.
        let bundle = info.bundleIdentifier

        guard let bundle = bundle else {
            Logger.info("⏭️ Now Playing source unknown (no bundle id) — ignoring", category: "playback")
            completion(false)
            return
        }

        if PlaybackEngine.isSupportedDesktopBundle(bundle) {
            acceptNowPlaying(info, artworkURL: nil, completion: completion)
            return
        }

        if let appName = PlaybackEngine.browserAppName(for: bundle) {
            // Browser source — only accept when a YouTube tab is actually open.
            // Guards against other websites (Netflix, SoundCloud, …) playing audio.
            verifyYouTubeTab(inApp: appName, trackTitle: info.title) { [weak self] verdict in
                switch verdict {
                case .youtube(let artworkURL):
                    self?.acceptNowPlaying(info, artworkURL: artworkURL, completion: completion)
                case .noMatchingYouTubeTab:
                    Logger.info("⏭️ \(appName) Now Playing title does not match any open YouTube tab — ignoring", category: "playback")
                    completion(false)
                case .cannotVerify:
                    Logger.info("⏭️ \(appName) Now Playing source could not be verified — ignoring", category: "playback")
                    completion(false)
                }
            }
            return
        }

        Logger.info("⏭️ Ignoring unsupported Now Playing source: \(bundle)", category: "playback")
        completion(false)
    }

    private func acceptNowPlaying(_ info: NowPlayingInfo, artworkURL: URL?, completion: @escaping (Bool) -> Void) {
        let title = info.title
        let artist = info.artist.isEmpty ? "Unknown Artist" : info.artist
        let duration = info.duration > 0 ? info.duration : 300.0
        Logger.info("🎵 Detected (NowPlaying): \(title) - \(artist) [\(String(format: "%.1f", info.elapsed))/\(String(format: "%.0f", duration))s] paused=\(info.isPaused)", category: "playback")
        DispatchQueue.main.async {
            self.updateTrack(title: title, artist: artist, duration: duration, elapsed: info.elapsed, isPaused: info.isPaused, isEstimatedProgress: false, artworkData: info.artworkData, artworkId: info.artworkId, artworkURL: artworkURL)
            completion(true)
        }
    }

    // MARK: - Playback Source Classification

    static func isSupportedDesktopBundle(_ bundle: String) -> Bool {
        let b = bundle.lowercased()
        return b.contains("youtube-music")
            || b.contains("ytmdesktop")
            || b == "com.spotify.client"
    }

    /// Maps a Now Playing bundle id (possibly a renderer/helper process) to the
    /// scriptable browser application name, or nil if it's not a known browser.
    /// Matches by token so helper bundle ids like `com.google.Chrome.helper`
    /// still resolve to the parent browser.
    private static func browserAppName(for bundle: String) -> String? {
        let b = bundle.lowercased()
        if b.contains("com.apple.safari")            { return "Safari" }
        if b.contains("com.google.chrome")           { return "Google Chrome" }
        if b.contains("thebrowser.dia")              { return "Dia" }
        if b.contains("thebrowser.browser")          { return "Arc" }
        if b.contains("brave")                       { return "Brave Browser" }
        if b.contains("edgemac") || b.contains("microsoft.edge") { return "Microsoft Edge" }
        if b.contains("vivaldi")                     { return "Vivaldi" }
        if b.contains("operasoftware.opera")         { return "Opera" }
        return nil
    }

    private enum YouTubeTabVerdict { case youtube(URL?), noMatchingYouTubeTab, cannotVerify }

    /// Reads tab titles and URLs (no JS execution → no suspended-tab hang) of
    /// the given browser before trusting MediaRemote.
    private func verifyYouTubeTab(inApp appName: String, trackTitle: String, completion: @escaping (YouTubeTabVerdict) -> Void) {
        let titleProperty = appName == "Safari" ? "name" : "title"
        let script = """
        set matches to ""
        tell application "\(appName)"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            set tabURL to URL of t
                            if tabURL contains "youtube.com" then
                                set tabTitle to \(titleProperty) of t
                                if matches is not "" then set matches to matches & linefeed
                                set matches to matches & tabTitle & "|||" & tabURL
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return matches
        """
        let maxAttempts = 3
        func attempt(_ attemptNumber: Int) {
            AppleScriptRunner.run(script, timeout: 2.0) { result in
                switch result {
                case .success(let out):
                    let candidates = YouTubeArtworkResolver.candidates(from: out)
                    switch YouTubeArtworkResolver.trackMatchState(in: candidates, trackTitle: trackTitle) {
                    case .matched:
                        completion(.youtube(YouTubeArtworkResolver.selectThumbnailURL(from: candidates, trackTitle: trackTitle)))
                    case .titleMismatch where attemptNumber < maxAttempts:
                        let nextAttempt = attemptNumber + 1
                        Logger.info("⏳ \(appName) YouTube tab title has not caught up with Now Playing; retrying (\(nextAttempt)/\(maxAttempts))", category: "playback")
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) {
                            attempt(nextAttempt)
                        }
                    case .titleMismatch, .noCandidates:
                        completion(.noMatchingYouTubeTab)
                    }
                case .failure:
                    completion(.cannotVerify)
                }
            }
        }
        attempt(1)
    }

    // MARK: - YouTube Music Desktop App API
    private func pollYTMDesktop(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://localhost:9863/query") else {
            completion(false)
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0.8
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error != nil {
                completion(false)
                return
            }
            
            guard let data = data else {
                completion(false)
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                guard let player = json?["player"] as? [String: Any],
                      let trackDict = json?["track"] as? [String: Any],
                      let hasSong = player["hasSong"] as? Bool, hasSong else {
                    completion(false)
                    return
                }
                
                let title = trackDict["title"] as? String ?? "Unknown Title"
                let artist = trackDict["author"] as? String ?? "Unknown Artist"
                let isPaused = player["isPaused"] as? Bool ?? true
                let duration = player["duration"] as? Double ?? 0.0
                let elapsed = player["seekbarCurrentPosition"] as? Double ?? 0.0
                
                DispatchQueue.main.async {
                    self.updateTrack(title: title, artist: artist, duration: duration, elapsed: elapsed, isPaused: isPaused, isEstimatedProgress: false)
                    completion(true)
                }
            } catch {
                completion(false)
            }
        }
        task.resume()
    }
    
    // MARK: - Arc Browser
    private func pollArc(completion: @escaping (Bool) -> Void) {
        guard isApplicationRunning("Arc") else { completion(false); return }
        let escapedJS = PlaybackEngine.escapeForAppleScript(PlaybackEngine.makeYTMExtractionJS())
        let escapedYTJS = PlaybackEngine.escapeForAppleScript(PlaybackEngine.makeYTExtractionJS())

        let script = """
        tell application "Arc"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            set tabURL to URL of t
                            if tabURL contains "music.youtube.com" then
                                try
                                    set result to execute t javascript "\(escapedJS)"
                                    if result is not "" then
                                        return "YTM|||" & result & "|||" & tabURL
                                    end if
                                on error
                                    set tabTitle to title of t
                                    return "TITLE|||" & tabTitle & "|||" & tabURL
                                end try
                            else if tabURL contains "youtube.com/watch" then
                                try
                                    set result to execute t javascript "\(escapedYTJS)"
                                    if result is not "" then
                                        return "YT|||" & result & "|||" & tabURL
                                    end if
                                on error
                                    set tabTitle to title of t
                                    return "TITLE|||" & tabTitle & "|||" & tabURL
                                end try
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
        
        AppleScriptRunner.run(script) { [weak self] result in
            self?.handleJSResult(result, completion: completion)
        }
    }
    
    // MARK: - Google Chrome
    private func pollChrome(completion: @escaping (Bool) -> Void) {
        guard isApplicationRunning("Google Chrome") else { completion(false); return }
        let escapedJS = PlaybackEngine.escapeForAppleScript(PlaybackEngine.makeYTMExtractionJS())
        let escapedYTJS = PlaybackEngine.escapeForAppleScript(PlaybackEngine.makeYTExtractionJS())

        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            set tabURL to URL of t
                            if tabURL contains "music.youtube.com" then
                                try
                                    set result to execute t javascript "\(escapedJS)"
                                    if result is not "" then
                                        return "YTM|||" & result & "|||" & tabURL
                                    end if
                                on error
                                    set tabTitle to title of t
                                    return "TITLE|||" & tabTitle & "|||" & tabURL
                                end try
                            else if tabURL contains "youtube.com/watch" then
                                try
                                    set result to execute t javascript "\(escapedYTJS)"
                                    if result is not "" then
                                        return "YT|||" & result & "|||" & tabURL
                                    end if
                                on error
                                    set tabTitle to title of t
                                    return "TITLE|||" & tabTitle & "|||" & tabURL
                                end try
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
        
        AppleScriptRunner.run(script) { [weak self] result in
            self?.handleJSResult(result, completion: completion)
        }
    }
    
    // MARK: - Safari
    private func pollSafari(completion: @escaping (Bool) -> Void) {
        guard isApplicationRunning("Safari") else { completion(false); return }
        let escapedJS = PlaybackEngine.escapeForAppleScript(PlaybackEngine.makeYTMExtractionJS())
        let escapedYTJS = PlaybackEngine.escapeForAppleScript(PlaybackEngine.makeYTExtractionJS())

        let script = """
        tell application "Safari"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            set tabURL to URL of t
                            if tabURL contains "music.youtube.com" then
                                try
                                    set result to do JavaScript "\(escapedJS)" in t
                                    if result is not "" then
                                        return "YTM|||" & result & "|||" & tabURL
                                    end if
                                on error
                                    set tabTitle to name of t
                                    return "TITLE|||" & tabTitle & "|||" & tabURL
                                end try
                            else if tabURL contains "youtube.com/watch" then
                                try
                                    set result to do JavaScript "\(escapedYTJS)" in t
                                    if result is not "" then
                                        return "YT|||" & result & "|||" & tabURL
                                    end if
                                on error
                                    set tabTitle to name of t
                                    return "TITLE|||" & tabTitle & "|||" & tabURL
                                end try
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
        
        AppleScriptRunner.run(script) { [weak self] result in
            self?.handleJSResult(result, completion: completion)
        }
    }
    
    // MARK: - JavaScript Result Handler
    private func handleJSResult(_ result: Result<String, Error>, completion: @escaping (Bool) -> Void) {
        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.isEmpty {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            // Check for prefix type
            if trimmed.hasPrefix("YTM|||") || trimmed.hasPrefix("YT|||") {
                // JavaScript extraction succeeded
                let prefixEnd = trimmed.hasPrefix("YTM|||") ? "YTM|||".count : "YT|||".count
                var payload = String(trimmed.dropFirst(prefixEnd))
                
                // AppleScript wraps JS string returns in double quotes — strip them
                if payload.hasPrefix("\"") && payload.hasSuffix("\"") && payload.count >= 2 {
                    payload = String(payload.dropFirst().dropLast())
                }
                
                let parts = payload.components(separatedBy: "|||")
                
                guard parts.count >= 5 else {
                    Logger.error("Unexpected parts count: \(parts.count) from payload: \(String(payload.prefix(100)))", category: "playback")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                var title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                var artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsedStr = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let durationStr = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let isPausedStr = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
                let artworkURL = parts.count > 5
                    ? URL(string: parts[5].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))))
                        .flatMap(YouTubeArtworkResolver.thumbnailURL(from:))
                    : nil
                
                // Strip wrapping quotes from AppleScript output
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                artist = artist.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                
                // Skip if no title
                if title.isEmpty || title.lowercased() == "youtube music" || title.lowercased() == "youtube" {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                // Default artist if empty
                if artist.isEmpty {
                    artist = "Unknown Artist"
                }
                
                let elapsed = Double(elapsedStr) ?? 0.0
                let duration = Double(durationStr) ?? 300.0
                let isPaused = isPausedStr.lowercased() == "true"
                
                Logger.info("🎵 Detected: \(title) - \(artist) [\(String(format: "%.1f", elapsed))/\(String(format: "%.0f", duration))s] paused=\(isPaused)", category: "playback")
                
                DispatchQueue.main.async {
                    self.updateTrack(title: title, artist: artist, duration: duration, elapsed: elapsed, isPaused: isPaused, isEstimatedProgress: false, artworkURL: artworkURL)
                    completion(true)
                }
                
            } else if trimmed.hasPrefix("TITLE|||") {
                // Fallback to tab title parsing
                let fallbackParts = String(trimmed.dropFirst("TITLE|||".count)).components(separatedBy: "|||")
                let tabTitle = fallbackParts[0]
                let artworkURL = fallbackParts.count > 1
                    ? URL(string: fallbackParts[1].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))))
                        .flatMap(YouTubeArtworkResolver.thumbnailURL(from:))
                    : nil
                let cleaned = cleanTrackTitle(tabTitle)
                
                let (title, artist) = parseTabTitle(cleaned)
                
                if title.isEmpty || title.lowercased() == "youtube music" || title.lowercased() == "youtube" {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                Logger.info("🎵 Detected (title fallback): \(title) - \(artist)", category: "playback")
                
                DispatchQueue.main.async {
                    self.updateTrack(title: title, artist: artist, duration: 300.0, elapsed: 0.0, isPaused: false, isEstimatedProgress: true, artworkURL: artworkURL)
                    completion(true)
                }
            } else {
                DispatchQueue.main.async { completion(false) }
            }
            
        case .failure(let error):
            Logger.error("AppleScript failed", category: "playback", error: error)
            DispatchQueue.main.async { completion(false) }
        }
    }
    
    // MARK: - Title Parsing Helpers
    private func cleanTrackTitle(_ rawTitle: String) -> String {
        var cleaned = rawTitle
        let suffixes = [
            " - YouTube Music",
            " | YouTube Music",
            " - YouTube",
            " | YouTube"
        ]
        for suffix in suffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func parseTabTitle(_ cleaned: String) -> (title: String, artist: String) {
        if cleaned.contains(" • ") {
            let chunks = cleaned.components(separatedBy: " • ")
            return (chunks[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    chunks[1].trimmingCharacters(in: .whitespacesAndNewlines))
        } else if cleaned.contains(" - ") {
            let chunks = cleaned.components(separatedBy: " - ")
            return (chunks[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    chunks.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), "Unknown Artist")
        }
    }
    
    // MARK: - Track State Management
    private func updateTrack(title: String, artist: String, duration: Double, elapsed: Double, isPaused: Bool, isEstimatedProgress: Bool, artworkData: Data? = nil, artworkId: String? = nil, artworkURL: URL? = nil) {
        let now = Date()
        if let current = currentTrack, current.title == title, current.artist == artist {
            var updated = current
            updated.isPaused = isPaused
            updated.duration = duration
            updated.isEstimatedProgress = isEstimatedProgress
            updated.artworkURL = artworkURL
            // Only overwrite artwork when source provides one — keeps existing
            // art across polls where the helper omits it.
            if let data = artworkData {
                updated.artworkData = data
                updated.artworkId = artworkId
            }

            if !isEstimatedProgress {
                if abs(elapsed - current.elapsedTime) > 0.5 {
                    updated.elapsedTime = elapsed
                    updated.lastUpdated = now
                } else if !isPaused {
                    let expectedTime = current.currentProgress
                    if abs(elapsed - expectedTime) > 2.0 {
                        updated.elapsedTime = elapsed
                        updated.lastUpdated = now
                    }
                }
            } else {
                updated.elapsedTime = current.elapsedTime
                updated.lastUpdated = current.lastUpdated
            }

            if currentTrack != updated {
                currentTrack = updated
            }
        } else {
            var newTrack = Track(title: title, artist: artist, syncOffsetKey: Track.makeSyncOffsetKey(title: title, artist: artist), duration: duration, elapsedTime: elapsed, isPaused: isPaused, lastUpdated: now, isEstimatedProgress: isEstimatedProgress)
            newTrack.artworkData = artworkData
            newTrack.artworkId = artworkId
            newTrack.artworkURL = artworkURL
            currentTrack = newTrack
            Logger.info("🎵 Track Changed: \(title) - \(artist) (Duration: \(duration)s)", category: "playback")
            triggerNotification(for: newTrack)
        }
    }
    
    // MARK: - Player Actions

    func togglePlayPause() {
        MediaKeys.send(MediaKeys.play)
        runJSInBrowsers("(function(){var v=document.querySelector('video');if(!v)return;if(v.paused){v.play().catch(function(){});}else{v.pause();}})()")
    }

    func nextTrack() {
        MediaKeys.send(MediaKeys.next)
        runJSInBrowsers("(function(){var b=document.querySelector('.next-button')||document.querySelector('[aria-label=\\\"Next\\\"]');if(b)b.click();})()")
    }

    func previousTrack() {
        MediaKeys.send(MediaKeys.previous)
        runJSInBrowsers("(function(){var b=document.querySelector('.previous-button')||document.querySelector('[aria-label=\\\"Previous\\\"]');if(b)b.click();})()")
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0.0, seconds)
        if let track = currentTrack {
            var updated = track
            updated.elapsedTime = clamped
            updated.lastUpdated = Date()
            currentTrack = updated
        }
        runJSInBrowsers("(function(){var v=document.querySelector('video');if(v){try{v.currentTime=\(clamped);}catch(e){}}})()")
    }

    private func runJSInBrowsers(_ jsCommand: String) {
        let arc = """
        tell application "Arc"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if URL of t contains "music.youtube.com" then
                            execute t javascript "\(jsCommand)"
                            return
                        end if
                    end repeat
                end try
            end repeat
        end tell
        """
        let chrome = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then
                        execute t javascript "\(jsCommand)"
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        let safari = """
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then
                        do JavaScript "\(jsCommand)" in t
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        AppleScriptRunner.run(arc) { _ in }
        AppleScriptRunner.run(chrome) { _ in }
        AppleScriptRunner.run(safari) { _ in }
    }

    func resolveTrackMetadata(title: String, artist: String) {
        if var current = currentTrack, current.title == title {
            current = Track(
                title: title,
                artist: artist,
                syncOffsetKey: current.syncOffsetKey,
                duration: current.duration,
                elapsedTime: current.elapsedTime,
                isPaused: current.isPaused,
                lastUpdated: current.lastUpdated,
                isEstimatedProgress: current.isEstimatedProgress
            )
            self.currentTrack = current
            Logger.info("📝 Resolved metadata: \(title) -> \(artist)", category: "playback")
        }
    }
    
    private func triggerNotification(for track: Track) {
        let content = UNMutableNotificationContent()
        content.title = "Now Playing"
        content.body = "\(track.title) by \(track.artist)"
        content.sound = .none
        
        let request = UNNotificationRequest(identifier: "TrackChanged", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.error("Failed to deliver track change notification", category: "playback", error: error)
            }
        }
    }
}
