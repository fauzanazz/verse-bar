import AppKit
import AVFoundation
import Combine
import Foundation

/// Scans the offline download folder into a sorted in-memory library.
/// Scanning is on-demand (launch, window open, download completion, Rescan);
/// cached metadata makes relaunch instant.
final class LibraryService: ObservableObject {
    static let shared = LibraryService()

    @Published private(set) var tracks: [LibraryTrack] = []   // always sorted addedAt DESC
    @Published private(set) var isScanning = false

    private let artworkCache = NSCache<NSString, NSImage>()
    private let storageURL: URL

    private init() {
        storageURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.playerstudio.PlayerStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        // Warm the window with the cached library, then rescan in the background.
        if let data = try? Data(contentsOf: storageURL.appendingPathComponent("Library.json")),
           let cached = try? JSONDecoder().decode([LibraryTrack].self, from: data) {
            tracks = cached.sorted { $0.addedAt > $1.addedAt }
        }
        refresh()
    }

    /// Async rescan of the download folder; safe to call repeatedly (no-op
    /// while a scan is already running).
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let snapshot = tracks
        Task { [weak self] in
            guard let self else { return }
            let scanned = await self.scan(cached: snapshot)
            await MainActor.run { [self] in
                self.tracks = scanned.sorted { $0.addedAt > $1.addedAt }
                self.isScanning = false
                self.persist()
                Logger.info("Library scan: \(self.tracks.count) tracks", category: "library")
            }
        }
    }

    /// Embedded artwork for a track, NSCache-backed; nil when the file has none
    /// (callers render a `music.note` placeholder).
    func artwork(for track: LibraryTrack) -> NSImage? {
        let key = track.id as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        // Remote streams have no cheap embedded art — AVURLAsset here would hit the
        // network on the caller's thread. YouTubeStreamService seeds the cache instead.
        guard track.streamURL == nil else { return nil }
        let asset = AVURLAsset(url: track.url)
        guard let item = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            filteredByIdentifier: .commonIdentifierArtwork
        ).first,
        let data = item.dataValue,
        let image = NSImage(data: data) else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }

    /// Seeds artwork for a track whose art cannot be read from a file (streams).
    func cacheArtwork(_ image: NSImage, for trackID: String) {
        artworkCache.setObject(image, forKey: trackID as NSString)
    }

    /// Moves the file to the Trash and rescans.
    func delete(_ track: LibraryTrack) {
        var urls = [track.url]
        let instrumental = VocalSeparationService.instrumentalURL(for: track)
        if FileManager.default.fileExists(atPath: instrumental.path) { urls.append(instrumental) }
        NSWorkspace.shared.recycle(urls) { _, _ in }
        tracks.removeAll { $0.id == track.id }
        refresh()
    }

    /// Splits a filename stem on the **first** `" - "`:
    /// `"Kendrick Lamar - luther"` → (artist: "Kendrick Lamar", title: "luther");
    /// no separator → (artist: "Unknown Artist", title: stem).
    static func parseFilename(_ stem: String) -> (artist: String, title: String) {
        if let range = stem.range(of: " - ") {
            let artist = stem[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = stem[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (artist.isEmpty ? "Unknown Artist" : artist, title)
        }
        return ("Unknown Artist", stem.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `Artist - Title.instrumental.mp3` is the karaoke sidecar of
    /// `Artist - Title.mp3` — never its own library entry.
    static func isInstrumentalSidecar(_ url: URL) -> Bool {
        url.deletingPathExtension().pathExtension.lowercased() == "instrumental"
    }

    private func persist() {
        let url = storageURL.appendingPathComponent("Library.json")
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func scan(cached: [LibraryTrack]) async -> [LibraryTrack] {
        let folder = AppSettings.shared.downloadFolder
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        let accepted = Set(["mp3", "m4a", "aac", "wav", "aiff", "flac"])

        var scanned: [LibraryTrack] = []
        for url in fileURLs(in: folder) {
            guard accepted.contains(url.pathExtension.lowercased()) else { continue }
            // `Artist - Title.instrumental.mp3` is the karaoke sidecar of
            // `Artist - Title.mp3` — never its own library entry.
            guard !Self.isInstrumentalSidecar(url) else { continue }
            let values = try? url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ])
            guard let modifiedAt = values?.contentModificationDate,
                  let fileSize = values?.fileSize else { continue }

            // Unchanged since the last scan — reuse the cached entry without
            // touching AVFoundation (this is what makes relaunch instant).
            if let existing = cachedByID[url.path],
               existing.modifiedAt == modifiedAt && existing.fileSize == fileSize {
                scanned.append(existing)
                continue
            }

            let stem = url.deletingPathExtension().lastPathComponent
            let meta = await readMetadata(for: url, stem: stem)
            scanned.append(LibraryTrack(
                id: url.path,
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                duration: meta.duration,
                addedAt: values?.creationDate ?? modifiedAt,
                modifiedAt: modifiedAt,
                fileSize: Int64(fileSize)
            ))
        }
        return scanned
    }

    /// Synchronous folder walk (kept out of the async `scan` so DirectoryEnumerator
    /// iteration stays legal in Swift 6 mode). Sub-folders count — a yt-dlp
    /// library may nest by artist.
    private func fileURLs(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    private func readMetadata(
        for url: URL,
        stem: String
    ) async -> (title: String, artist: String, album: String?, duration: TimeInterval) {
        let (fallbackArtist, fallbackTitle) = Self.parseFilename(stem)
        let asset = AVURLAsset(url: url)

        let duration: TimeInterval
        if let loaded = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(loaded)
        } else {
            duration = 0
        }

        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func text(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: identifier
            ).first else { return nil }
            let value = (try? await item.load(.stringValue))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }

        return (
            title: (await text(.commonIdentifierTitle)) ?? fallbackTitle,
            artist: (await text(.commonIdentifierArtist)) ?? fallbackArtist,
            album: await text(.commonIdentifierAlbumName),
            duration: duration
        )
    }
}
