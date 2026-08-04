import Foundation
import XCTest
@testable import PlayerStudio

final class YouTubeStreamServiceTests: XCTestCase {
    func testParseStreamURLFromCleanOutput() {
        let url = "https://rr3---sn.googlevideo.com/videoplayback/expire=1/sig=abc"
        XCTAssertEqual(
            YouTubeStreamService.parseStreamURL(from: url),
            URL(string: url)
        )
    }

    func testParseStreamURLLastHttpsLineWhenWarningFirst() {
        let output = """
        WARNING: [youtube] dQw4w9WgXcQ: nsig extraction failed
        https://rr3---sn.googlevideo.com/videoplayback/expire=1
        """
        XCTAssertEqual(
            YouTubeStreamService.parseStreamURL(from: output),
            URL(string: "https://rr3---sn.googlevideo.com/videoplayback/expire=1")
        )
    }

    func testParseStreamURLNilForEmptyOutput() {
        XCTAssertNil(YouTubeStreamService.parseStreamURL(from: ""))
        XCTAssertNil(YouTubeStreamService.parseStreamURL(from: "\n\n"))
    }

    func testParseStreamURLNilForNonURLOutput() {
        XCTAssertNil(YouTubeStreamService.parseStreamURL(from: "ERROR: unable to extract"))
        XCTAssertNil(YouTubeStreamService.parseStreamURL(from: "[info] https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }
}
