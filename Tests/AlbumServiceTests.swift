import XCTest
@testable import PlayerStudio

final class AlbumServiceTests: XCTestCase {
    // The reorder/remove translation is pure and lives on AlbumService;
    // AlbumService itself is a persisting singleton, so only the translation
    // is unit-tested here.

    func testReorderMoveFirstToEnd() {
        let result = AlbumService.reordered(
            trackIDs: ["a", "b", "c"],
            resolved: ["a", "b", "c"],
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )
        XCTAssertEqual(result, ["b", "c", "a"])
    }

    func testReorderMoveLastToFront() {
        let result = AlbumService.reordered(
            trackIDs: ["a", "b", "c"],
            resolved: ["a", "b", "c"],
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    func testReorderKeepsMissingFileParked() {
        // "gone" has no library file: offsets index the resolved list, and the
        // moved "b" lands before "a" while "gone" stays in place.
        let result = AlbumService.reordered(
            trackIDs: ["a", "gone", "b"],
            resolved: ["a", "b"],
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )
        XCTAssertEqual(result, ["b", "a", "gone"])
    }

    func testRemoveTranslatesThroughResolvedList() {
        let result = AlbumService.removed(
            trackIDs: ["a", "gone", "b"],
            resolved: ["a", "b"],
            atOffsets: IndexSet(integer: 1)
        )
        XCTAssertEqual(result, ["a", "gone"])
    }
}
