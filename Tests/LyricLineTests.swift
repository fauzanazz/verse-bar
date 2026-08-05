import XCTest
@testable import PlayerStudio

final class LyricLineTests: XCTestCase {
    func testMakeWordsSpansLineContinuously() {
        let words = LyricLine.makeWords(
            text: "I got my driver's license",
            start: 8.5,
            end: 11.8
        )

        XCTAssertEqual(words.count, 5)
        XCTAssertEqual(words.first!.start, 8.5, accuracy: 0.001)
        XCTAssertEqual(words.last!.end, 11.8, accuracy: 0.001)
        for (word, nextWord) in zip(words, words.dropFirst()) {
            XCTAssertEqual(word.end, nextWord.start, accuracy: 0.001)
        }
    }

    func testMakeWordsWeightsLongerTokensMoreHeavily() {
        let words = LyricLine.makeWords(
            text: "I got my driver's license",
            start: 8.5,
            end: 11.8
        )

        let myDuration = words[2].end - words[2].start
        let driversDuration = words[3].end - words[3].start
        XCTAssertGreaterThan(driversDuration, myDuration)
    }

    func testMakeWordsReturnsEmptyForEmptyText() {
        XCTAssertEqual(LyricLine.makeWords(text: "", start: 1, end: 2), [])
    }

    func testMakeWordsSingleTokenSpansFullDuration() {
        let words = LyricLine.makeWords(text: "Hello", start: 2, end: 5)

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].start, 2, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 5, accuracy: 0.001)
    }

    func testMakeLinesUsesWordTimingWhenPresent() {
        let lines = LyricLine.makeLines([
            .init(timestamp: 8.5, body: "I <00:08.67>got <00:08.97>my")
        ])

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "I got my")
        XCTAssertEqual(lines[0].words.count, 3)
        XCTAssertEqual(lines[0].words[0].start, 8.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].start, 8.67, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[2].start, 8.97, accuracy: 0.001)
    }

    func testMakeLinesWordEndsComeFromNextTag() {
        let lines = LyricLine.makeLines([
            .init(timestamp: 8.5, body: "I <00:08.67>got <00:08.97>my")
        ])

        XCTAssertEqual(lines[0].words[0].end, 8.67, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].end, 8.97, accuracy: 0.001)
    }

    func testMakeLinesDoesNotStretchIntoInstrumentalGap() {
        let lines = LyricLine.makeLines([
            .init(timestamp: 0, body: "First line"),
            .init(timestamp: 30, body: "Second line")
        ])

        XCTAssertLessThan(lines[0].words.last!.end, 3.0)
    }

    func testMakeLinesStillClipsAtNextLineWhenTight() {
        let lines = LyricLine.makeLines([
            .init(timestamp: 0, body: "First line"),
            .init(timestamp: 0.8, body: "Second line")
        ])

        XCTAssertEqual(lines[0].words.last!.end, 0.8, accuracy: 0.001)
    }

    func testEstimatedSingingDurationWeightsSyllabicScriptsHeavier() {
        XCTAssertGreaterThan(
            LyricLine.estimatedSingingDuration("사랑해요"),
            LyricLine.estimatedSingingDuration("love")
        )
    }

    func testMakeLinesFallsBackToInterpolationWithoutTags() {
        let lines = LyricLine.makeLines([
            .init(timestamp: 1, body: "no tags here")
        ])

        XCTAssertEqual(lines[0].words.count, 3)
        XCTAssertEqual(lines[0].words[0].start, 1, accuracy: 0.001)
    }

    func testStripInlineWordTags() {
        XCTAssertEqual(
            LyricLine.stripInlineWordTags("I <00:08.67>got <00:08.97>my"),
            "I got my"
        )
    }
}
