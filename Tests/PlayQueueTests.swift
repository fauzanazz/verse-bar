import XCTest
@testable import PlayerStudio

final class PlayQueueTests: XCTestCase {
    private func tracks(_ count: Int) -> [LibraryTrack] {
        (0..<count).map { i in
            LibraryTrack(
                id: "/tmp/track\(i).mp3",
                title: "Title \(i)",
                artist: "Artist",
                album: nil,
                duration: 100,
                addedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                fileSize: 1
            )
        }
    }

    func testAdvanceWalksThenStopsWithRepeatOff() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 0)
        XCTAssertEqual(queue.current, three[0])
        XCTAssertEqual(queue.advance(), three[1])
        XCTAssertEqual(queue.advance(), three[2])
        XCTAssertNil(queue.advance())
        XCTAssertEqual(queue.current, three[2])  // stays parked on the last track
    }

    func testAdvanceWrapsToStartWithRepeatAll() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 1)
        queue.repeatMode = .all
        XCTAssertEqual(queue.advance(), three[2])
        XCTAssertEqual(queue.advance(), three[0])
        XCTAssertEqual(queue.advance(), three[1])
    }

    func testAdvanceReturnsSameTrackWithRepeatOne() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 1)
        queue.repeatMode = .one
        XCTAssertEqual(queue.advance(), three[1])
        XCTAssertEqual(queue.current, three[1])
    }

    func testRewindFromPositionZeroStaysOnFirstTrack() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 0)
        XCTAssertEqual(queue.rewind(), three[0])
        XCTAssertEqual(queue.rewind(), three[0])
    }

    func testSetShuffledKeepsCurrentAndOrderHasNoDuplicates() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 1)
        let current = queue.current
        queue.setShuffled(true)
        XCTAssertEqual(queue.current, current)
        XCTAssertEqual(queue.order.count, 3)
        XCTAssertEqual(Set(queue.order).count, 3)
    }

    func testInsertNextPlaysInsertedTrackOnNextAdvance() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 0)
        let extra = tracks(1)[0]
        queue.insertNext(extra)
        XCTAssertEqual(queue.advance(), extra)
        // The rest of the original order follows.
        XCTAssertEqual(queue.upNext, [three[1], three[2]])
    }

    func testAppendAddsToEndOfQueue() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 0)
        let extra = tracks(1)[0]
        queue.append(extra)
        XCTAssertEqual(queue.upNext, [three[1], three[2], extra])
    }

    func testSetDurationUpdatesMatchingTrack() {
        let three = tracks(3)
        var queue = PlayQueue()
        queue.load(three, startAt: 0)
        queue.setDuration(42.5, forTrackID: "/tmp/track1.mp3")
        XCTAssertEqual(queue.tracks[1].duration, 42.5)
        // Other tracks untouched.
        XCTAssertEqual(queue.tracks[0].duration, 100)
        XCTAssertEqual(queue.tracks[2].duration, 100)
    }

    func testSetDurationIsNoOpForUnknownID() {
        var queue = PlayQueue()
        queue.load(tracks(1), startAt: 0)
        queue.setDuration(42.5, forTrackID: "/tmp/nope.mp3")
        XCTAssertEqual(queue.current?.duration, 100)
        XCTAssertEqual(queue.tracks[0].duration, 100)
    }
}
