import Foundation
import XCTest
@testable import PlayerStudio

final class VocalSeparationServiceTests: XCTestCase {
    private func track(id: String) -> LibraryTrack {
        LibraryTrack(
            id: id,
            title: "luther",
            artist: "Kendrick Lamar",
            album: nil,
            duration: 0,
            addedAt: Date(),
            modifiedAt: Date(),
            fileSize: 0
        )
    }

    func testInstrumentalURLDerivation() {
        XCTAssertEqual(
            VocalSeparationService.instrumentalURL(for: track(id: "/tmp/Kendrick Lamar - luther.mp3")).path,
            "/tmp/Kendrick Lamar - luther.instrumental.mp3"
        )
        // Always `.mp3` regardless of the source's extension (Demucs runs with `--mp3`).
        XCTAssertEqual(
            VocalSeparationService.instrumentalURL(for: track(id: "/tmp/Kendrick Lamar - luther.flac")).path,
            "/tmp/Kendrick Lamar - luther.instrumental.mp3"
        )
    }

    func testParseProgressReadsTqdmBar() {
        XCTAssertEqual(
            VocalSeparationService.parseProgress(from: " 45%|████      | 132.0/292.5 [00:12<00:14]"),
            45
        )
        XCTAssertEqual(
            VocalSeparationService.parseProgress(from: "100%|██████████| 292.5/292.5 [00:25<00:00]"),
            100
        )
        XCTAssertNil(VocalSeparationService.parseProgress(from: "Separating track 1/1"))
    }

    func testInstrumentalSidecarIsDetected() {
        XCTAssertTrue(LibraryService.isInstrumentalSidecar(URL(fileURLWithPath: "/tmp/A - B.instrumental.mp3")))
        XCTAssertTrue(LibraryService.isInstrumentalSidecar(URL(fileURLWithPath: "/tmp/A - B.instrumental.MP3")))
        XCTAssertFalse(LibraryService.isInstrumentalSidecar(URL(fileURLWithPath: "/tmp/A - B.mp3")))
        // No audio extension — never scanned anyway, but must not match.
        XCTAssertFalse(LibraryService.isInstrumentalSidecar(URL(fileURLWithPath: "/tmp/A - B.instrumental")))
    }
}
