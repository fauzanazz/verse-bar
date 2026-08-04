import Foundation

enum RepeatMode: String, Codable {
    case off, all, one
}

/// Pure value type — no AVFoundation — so queue semantics are unit-testable.
///
/// Contract:
/// - `load`: order = track indices; when shuffled, current track first then
///   the rest shuffled and position = 0; else position = startAt.
/// - `advance`: `.one` returns the current track unchanged (caller restarts the
///   file at 0). Else position += 1; past the end → `.all` wraps to 0 and
///   returns the new current, otherwise stays at the last index and returns nil.
/// - `rewind`: position = max(0, position - 1).
/// - `setShuffled`: keeps the current track; unshuffling restores index order.
/// - `insertNext`/`append`: append to `tracks`; `insertNext` slots the new
///   index right after `position` so it plays next.
struct PlayQueue: Equatable {
    private(set) var tracks: [LibraryTrack] = []
    private(set) var order: [Int] = []       // indices into `tracks`
    private(set) var position: Int = 0       // index into `order`
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off

    var current: LibraryTrack? {
        order.indices.contains(position) ? tracks[order[position]] : nil
    }
    var upNext: [LibraryTrack] {
        order.dropFirst(position + 1).map { tracks[$0] }
    }

    mutating func load(_ tracks: [LibraryTrack], startAt index: Int) {
        self.tracks = tracks
        if isShuffled {
            order = [index] + tracks.indices.filter { $0 != index }.shuffled()
            position = 0
        } else {
            order = Array(tracks.indices)
            position = index
        }
    }

    mutating func setShuffled(_ on: Bool) {
        guard on != isShuffled else { return }
        isShuffled = on
        let currentIndex = current.flatMap { current in tracks.firstIndex(of: current) }
        if on {
            order = [currentIndex ?? 0] + tracks.indices.filter { $0 != currentIndex }.shuffled()
            position = 0
        } else {
            order = Array(tracks.indices)
            position = currentIndex.flatMap { order.firstIndex(of: $0) } ?? 0
        }
    }

    /// Returns the track to play next, or nil when playback should stop.
    mutating func advance() -> LibraryTrack? {
        guard !order.isEmpty else { return nil }
        if repeatMode == .one {
            return current
        }
        position += 1
        if position >= order.count {
            if repeatMode == .all {
                position = 0
                return current
            }
            position = order.count - 1
            return nil
        }
        return current
    }

    mutating func rewind() -> LibraryTrack? {
        guard !order.isEmpty else { return nil }
        position = max(0, position - 1)
        return current
    }

    mutating func insertNext(_ track: LibraryTrack) {
        tracks.append(track)
        let index = tracks.count - 1
        order.insert(index, at: min(position + 1, order.count))
    }

    mutating func append(_ track: LibraryTrack) {
        tracks.append(track)
        order.append(tracks.count - 1)
    }

    /// Fills in a duration discovered at load time (streams often only know it
    /// once the asset is ready).
    mutating func setDuration(_ duration: TimeInterval, forTrackID id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].duration = duration
    }
}
