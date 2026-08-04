import Foundation

/// One file in the offline library. `id` is the absolute file path — the
/// identity used everywhere (queues, artwork cache, deletion).
struct LibraryTrack: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval
    var addedAt: Date         // file creationDate ?? contentModificationDate
    var modifiedAt: Date      // contentModificationDate — cache invalidation
    var fileSize: Int64       // cache invalidation
    /// Set only for remote streams (Browse ▶); library files leave it nil.
    var streamURL: URL? = nil

    var url: URL { streamURL ?? URL(fileURLWithPath: id) }

    /// `"yt:<videoID>"` ids come from Browse ▶ — used for stream refresh and
    /// download dedup.
    var youtubeID: String? {
        streamURL != nil && id.hasPrefix("yt:") ? String(id.dropFirst(3)) : nil
    }

    /// Matches ListeningStatsService.identityKey for non-YouTube tracks.
    var statsKey: String { "ta:" + Track.makeSyncOffsetKey(title: title, artist: artist) }
}
