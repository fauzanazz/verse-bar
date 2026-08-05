import AppKit
import Foundation

/// User-created albums (title, description, cover, ordered track ids).
/// Persistence mirrors `LibraryService`: JSON in Application Support, cover
/// PNGs in a Covers/ subdirectory. Album identity is the `LibraryTrack.id`
/// string; tracks whose files vanish stay in `trackIDs` and are simply
/// hidden from the resolved list until a rescan restores them.
final class AlbumService: ObservableObject {
    static let shared = AlbumService()

    @Published private(set) var albums: [Album] = []   // always sorted createdAt DESC

    private let coverCache = NSCache<NSString, NSImage>()
    private let storageURL: URL

    private init() {
        storageURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.playerstudio.PlayerStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: storageURL.appendingPathComponent("Covers", isDirectory: true),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: storageURL.appendingPathComponent("Albums.json")),
           let decoded = try? JSONDecoder().decode([Album].self, from: data) {
            albums = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - Mutation (every mutator bumps updatedAt then persist())

    @discardableResult
    func create(title: String, description: String, cover: NSImage?) -> Album {
        var album = Album(
            id: UUID().uuidString,
            title: cleanedTitle(title),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            trackIDs: [],
            hasCover: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        if let cover {
            album.hasCover = writeCover(cover, for: album.id)
        }
        albums.append(album)
        albums.sort { $0.createdAt > $1.createdAt }
        persist()
        return album
    }

    func update(id: String, title: String, description: String, cover: NSImage?, clearCover: Bool) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].title = cleanedTitle(title)
        albums[index].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cover {
            albums[index].hasCover = writeCover(cover, for: id)
        } else if clearCover {
            try? FileManager.default.removeItem(at: Self.coverURL(for: id, in: storageURL))
            albums[index].hasCover = false
            coverCache.removeObject(forKey: id as NSString)
        }
        albums[index].updatedAt = Date()
        persist()
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: Self.coverURL(for: id, in: storageURL))
        coverCache.removeObject(forKey: id as NSString)
        albums.removeAll { $0.id == id }
        persist()
    }

    /// Appends `trackIDs`, skipping ids already present (argument order kept
    /// for the new ones).
    func addTracks(_ trackIDs: [String], to albumID: String) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        var seen = Set(albums[index].trackIDs)
        albums[index].trackIDs.append(contentsOf: trackIDs.filter { seen.insert($0).inserted })
        albums[index].updatedAt = Date()
        persist()
    }

    /// `offsets` are positions in the *resolved* track list; ids that have no
    /// library file stay parked in `trackIDs` and are never touched.
    func removeTracks(atOffsets offsets: IndexSet, from albumID: String) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].trackIDs = Self.removed(
            trackIDs: albums[index].trackIDs,
            resolved: tracks(in: albums[index]).map(\.id),
            atOffsets: offsets
        )
        albums[index].updatedAt = Date()
        persist()
    }

    func moveTracks(fromOffsets offsets: IndexSet, toOffset destination: Int, in albumID: String) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].trackIDs = Self.reordered(
            trackIDs: albums[index].trackIDs,
            resolved: tracks(in: albums[index]).map(\.id),
            fromOffsets: offsets,
            toOffset: destination
        )
        albums[index].updatedAt = Date()
        persist()
    }

    // MARK: - Reads

    /// `album.trackIDs` order, ids missing from the live library dropped.
    func tracks(in album: Album) -> [LibraryTrack] {
        let byID = Dictionary(
            LibraryService.shared.tracks.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        return album.trackIDs.compactMap { byID[$0] }
    }

    /// Cover PNG, NSCache-backed by album id; nil when `hasCover` is false.
    func cover(for album: Album) -> NSImage? {
        guard album.hasCover else { return nil }
        let key = album.id as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: Self.coverURL(for: album.id, in: storageURL)),
              let image = NSImage(data: data) else { return nil }
        coverCache.setObject(image, forKey: key)
        return image
    }

    static func coverURL(for albumID: String, in directory: URL) -> URL {
        directory.appendingPathComponent("Covers", isDirectory: true)
            .appendingPathComponent("\(albumID).png")
    }

    // MARK: - Offset translation (pure, unit-tested)

    /// `offsets`/`destination` are positions in `resolved` (the resolved track
    /// id list). The moved block lands before the id originally at
    /// `destination`; `destination == resolved.count` appends. Ids in
    /// `trackIDs` that are absent from `resolved` are left parked where they
    /// are. Matches `Array.move(fromOffsets:toOffset:)` semantics, which is
    /// what SwiftUI `.onMove` feeds it.
    static func reordered(trackIDs: [String], resolved: [String], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [String] {
        let moving = offsets.count
        guard moving > 0 else { return trackIDs }
        let movedIDs = offsets.compactMap { resolved.indices.contains($0) ? resolved[$0] : nil }
        var result = trackIDs.filter { !movedIDs.contains($0) }
        let insertAt: Int
        if destination < resolved.count {
            insertAt = result.firstIndex(of: resolved[destination]) ?? result.count
        } else {
            insertAt = result.count
        }
        result.insert(contentsOf: movedIDs, at: insertAt)
        return result
    }

    /// Removes the `resolved` ids at `offsets` from `trackIDs`.
    static func removed(trackIDs: [String], resolved: [String], atOffsets offsets: IndexSet) -> [String] {
        let removedIDs = Set(offsets.compactMap { resolved.indices.contains($0) ? resolved[$0] : nil })
        return trackIDs.filter { !removedIDs.contains($0) }
    }

    // MARK: - Private

    private func cleanedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Album" : trimmed
    }

    private func writeCover(_ image: NSImage, for albumID: String) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: Self.coverURL(for: albumID, in: storageURL), options: .atomic)
            coverCache.removeObject(forKey: albumID as NSString)
            return true
        } catch {
            return false
        }
    }

    private func persist() {
        let url = storageURL.appendingPathComponent("Albums.json")
        guard let data = try? JSONEncoder().encode(albums) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
