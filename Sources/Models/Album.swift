import Foundation

/// A user-created collection of library tracks. `trackIDs` are `LibraryTrack.id`
/// values (absolute file paths); resolution against the live library happens in
/// `AlbumService.tracks(in:)`, so a temporarily missing file is skipped, not lost.
struct Album: Identifiable, Codable, Equatable {
    let id: String              // UUID().uuidString
    var title: String
    var description: String     // "" when unset
    var trackIDs: [String]
    var hasCover: Bool          // cover PNG exists at AlbumService.coverURL(for:)
    let createdAt: Date
    var updatedAt: Date
}
