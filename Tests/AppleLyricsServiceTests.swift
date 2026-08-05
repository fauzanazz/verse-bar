import XCTest
@testable import PlayerStudio

final class AppleLyricsServiceTests: XCTestCase {
    // Verified live response shape from lyrics.paxsenix.org (Bertaut, first line).
    private let syllableFixture = """
    {"provider":"apple_music","syncType":"Syllable","source":"local_cache",
     "lyrics":[{"timestamp":21388,"endtime":28526,"duration":7138,"structure":"Verse",
       "text":[{"text":"Bun,","timestamp":21388,"endtime":22423,"duration":1035,"part":false},
               {"text":"hi","timestamp":22423,"endtime":22770,"duration":347,"part":true},
               {"text":"dup","timestamp":22770,"endtime":23215,"duration":445,"part":false}],
       "background":false,"backgroundText":[],"oppositeTurn":false,
       "agent":"v1","key":"L1","sectionBegin":21388,"sectionEnd":48621}]}
    """

    func testParseSyllableLyricsConvertsMillisecondsAndSkipsInterpolation() throws {
        let lines = try AppleLyricsService.parseSyllableLyrics(Data(syllableFixture.utf8))

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].timestamp, 21.388, accuracy: 0.001)
        XCTAssertEqual(lines[0].words.count, 3)
        XCTAssertEqual(lines[0].words[0].start, 21.388, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].start, 22.423, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[2].end, 23.215, accuracy: 0.001)
    }

    func testParseJoinsPartTokens() throws {
        let lines = try AppleLyricsService.parseSyllableLyrics(Data(syllableFixture.utf8))

        XCTAssertEqual(lines[0].words[1].joinsNext, true)
        XCTAssertEqual(lines[0].words[0].joinsNext, false)
        XCTAssertEqual(lines[0].text, "Bun, hidup")
    }

    func testParseRejectsLineSyncedPayload() {
        let payload = #"{"syncType":"Line","lyrics":[]}"#
        XCTAssertThrowsError(try AppleLyricsService.parseSyllableLyrics(Data(payload.utf8))) { error in
            XCTAssertEqual(error as? AppleLyricsService.AppleLyricsError, .notSyllableSynced)
        }
    }

    func testParseRejectsEmptyPayload() {
        let payload = #"{"syncType":"Syllable","lyrics":[]}"#
        XCTAssertThrowsError(try AppleLyricsService.parseSyllableLyrics(Data(payload.utf8))) { error in
            XCTAssertEqual(error as? AppleLyricsService.AppleLyricsError, .empty)
        }
    }

    private func candidate(_ trackId: Int, name: String, artist: String = "Nadin Amizah", millis: Int?) -> AppleLyricsService.Candidate {
        AppleLyricsService.Candidate(trackId: trackId, trackName: name, artistName: artist, trackTimeMillis: millis)
    }

    func testPickCandidatePrefersDurationMatch() {
        let results = [
            candidate(1, name: "Bertaut", millis: 240_000),
            candidate(2, name: "Bertaut", millis: 315_000),
        ]
        let picked = AppleLyricsService.pickCandidate(results, title: "Bertaut", artist: "Nadin Amizah", duration: 315.96)
        XCTAssertEqual(picked?.trackId, 2)
    }

    func testPickCandidateRejectsDurationMismatch() {
        let results = [candidate(1, name: "Bertaut", millis: 315_000)]
        XCTAssertNil(AppleLyricsService.pickCandidate(results, title: "Bertaut", artist: "Nadin Amizah", duration: 100))
    }

    func testPickCandidateRejectsUnrelatedTitle() {
        let results = [candidate(1, name: "Blinding Lights", artist: "The Weeknd", millis: 200_000)]
        XCTAssertNil(AppleLyricsService.pickCandidate(results, title: "Bertaut", artist: "Nadin Amizah", duration: 315.96))
    }

    func testSearchTermStripsBracketsAndPipe() {
        XCTAssertEqual(
            AppleLyricsService.searchTerm(title: "Bertaut (Official MV) | Live", artist: "Nadin Amizah"),
            "Bertaut Nadin Amizah"
        )
    }

    func testSearchTermSkipsGenericArtist() {
        XCTAssertEqual(AppleLyricsService.searchTerm(title: "Some Song", artist: "Unknown Artist"), "Some Song")
    }
}
