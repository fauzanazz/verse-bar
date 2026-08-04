import Foundation
import XCTest
@testable import PlayerStudio

final class YouTubeDownloadServiceTests: XCTestCase {
    func testParseProgressAcceptsYtDlpNewlineOutput() {
        XCTAssertEqual(
            YouTubeDownloadService.parseProgress(from: "[download]  45.3% of 3.42MiB at 1.2MiB/s ETA 00:02"),
            45.3
        )
        XCTAssertEqual(
            YouTubeDownloadService.parseProgress(from: "[download] 100% of 246.27KiB in 00:00:00"),
            100
        )
        XCTAssertEqual(YouTubeDownloadService.parseProgress(from: "[download]   0.4% of 246.27KiB at 28.52KiB/s"), 0.4)
    }

    func testParseProgressIgnoresNonProgressLines() {
        XCTAssertNil(YouTubeDownloadService.parseProgress(from: "[ExtractAudio] Destination: jawed - Me at the zoo.mp3"))
        XCTAssertNil(YouTubeDownloadService.parseProgress(from: "jawed - Me at the zoo.mp3"))
        XCTAssertNil(YouTubeDownloadService.parseProgress(from: "[download] Destination: jawed - Me at the zoo.webm"))
    }
}
