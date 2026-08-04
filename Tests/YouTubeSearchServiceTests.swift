import XCTest
@testable import PlayerStudio

final class YouTubeSearchServiceTests: XCTestCase {
    func testParseResultsFromYtDlpDumpSingleJson() {
        let json = """
        {"entries":[{"id":"HfWLgELllZs","title":"Kendrick Lamar - luther (Official Audio)","uploader":"Kendrick Lamar","channel":"Kendrick Lamar","duration":178},
                    {"id":"sNY_2TEmzho","title":"Kendrick Lamar, SZA - luther","uploader":"Kendrick Lamar","duration":312},
                    {"title":"no id here"}]}
        """
        let results = YouTubeSearchService.parseResults(from: Data(json.utf8))

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "HfWLgELllZs")
        XCTAssertEqual(results[0].title, "Kendrick Lamar - luther (Official Audio)")
        XCTAssertEqual(results[0].channel, "Kendrick Lamar")
        XCTAssertEqual(results[0].duration, 178)
        XCTAssertEqual(results[0].url, "https://www.youtube.com/watch?v=HfWLgELllZs")
        XCTAssertEqual(results[1].id, "sNY_2TEmzho")
        XCTAssertEqual(results[1].channel, "Kendrick Lamar")
        XCTAssertEqual(results[1].duration, 312)
    }

    func testParseResultsFallsBackToChannelField() {
        let json = """
        {"entries":[{"id":"abc12345678","title":"Some video","channel":"Some Channel"}]}
        """
        let results = YouTubeSearchService.parseResults(from: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].channel, "Some Channel")
        XCTAssertNil(results[0].duration)
    }

    func testParseResultsRejectsGarbage() {
        XCTAssertTrue(YouTubeSearchService.parseResults(from: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(YouTubeSearchService.parseResults(from: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(YouTubeSearchService.parseResults(from: Data("{\"entries\":[]}".utf8)).isEmpty)
    }
}
