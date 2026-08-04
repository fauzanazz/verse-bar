import XCTest
@testable import PlayerStudio

final class LibraryServiceTests: XCTestCase {
    func testParseFilenameSplitsOnFirstSeparator() {
        let (artist, title) = LibraryService.parseFilename("Kendrick Lamar - luther")
        XCTAssertEqual(artist, "Kendrick Lamar")
        XCTAssertEqual(title, "luther")
    }

    func testParseFilenameWithoutSeparatorUsesUnknownArtist() {
        let (artist, title) = LibraryService.parseFilename("Me at the zoo")
        XCTAssertEqual(artist, "Unknown Artist")
        XCTAssertEqual(title, "Me at the zoo")
    }

    func testParseFilenameKeepsRemainderInTitle() {
        let (artist, title) = LibraryService.parseFilename("A - B - C")
        XCTAssertEqual(artist, "A")
        XCTAssertEqual(title, "B - C")
    }

    func testParseFilenameTrimsWhitespace() {
        let (artist, title) = LibraryService.parseFilename("  Kendrick Lamar  -  luther  ")
        XCTAssertEqual(artist, "Kendrick Lamar")
        XCTAssertEqual(title, "luther")
    }
}
