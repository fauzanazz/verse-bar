import Foundation
import XCTest
@testable import VerseBar

final class DiscordPresenceServiceTests: XCTestCase {
    func testCodecBuffersFragmentedFrames() throws {
        let frame = DiscordIPCFrame(opcode: 1, payload: Data("hello".utf8))
        let encoded = try DiscordIPCCodec.encode(frame)
        var buffer = Data(encoded.prefix(6))

        XCTAssertEqual(try DiscordIPCCodec.decodeAvailable(from: &buffer), [])
        XCTAssertEqual(buffer, encoded.prefix(6))

        buffer.append(encoded.dropFirst(6))
        XCTAssertEqual(try DiscordIPCCodec.decodeAvailable(from: &buffer), [frame])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCodecUsesLittleEndianHeader() throws {
        let encoded = try DiscordIPCCodec.encode(
            DiscordIPCFrame(opcode: 0x0102_0304, payload: Data([0xAA, 0xBB]))
        )
        XCTAssertEqual(Array(encoded.prefix(8)), [0x04, 0x03, 0x02, 0x01, 0x02, 0, 0, 0])
    }

    func testCodecRejectsPayloadAboveFrameLimit() {
        let payload = Data(repeating: 0, count: 65_529)
        XCTAssertThrowsError(try DiscordIPCCodec.encode(DiscordIPCFrame(opcode: 1, payload: payload))) {
            XCTAssertEqual($0 as? DiscordIPCCodec.CodecError, .payloadTooLarge(65_529))
        }

        var oversizedHeader = Data([1, 0, 0, 0, 0xF9, 0xFF, 0, 0])
        XCTAssertThrowsError(try DiscordIPCCodec.decodeAvailable(from: &oversizedHeader)) {
            XCTAssertEqual($0 as? DiscordIPCCodec.CodecError, .payloadTooLarge(65_529))
        }
    }

    func testHandshakePayload() throws {
        let payload = try jsonObject(DiscordRPCPayload.handshake(clientID: "1528023960774774815"))
        XCTAssertEqual(payload["v"] as? Int, 1)
        XCTAssertEqual(payload["client_id"] as? String, "1528023960774774815")
        XCTAssertEqual(Set(payload.keys), ["v", "client_id"])
    }

    func testActivityPayloadUsesListeningTypeAndMetadata() throws {
        let payload = try jsonObject(DiscordRPCPayload.activity(
            pid: 123,
            title: "Track title",
            artist: "Track artist",
            nonce: "activity-nonce"
        ))
        let args = try XCTUnwrap(payload["args"] as? [String: Any])
        let activity = try XCTUnwrap(args["activity"] as? [String: Any])

        XCTAssertEqual(payload["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertEqual(payload["nonce"] as? String, "activity-nonce")
        XCTAssertEqual(args["pid"] as? Int, 123)
        XCTAssertEqual(activity["type"] as? Int, 2)
        XCTAssertEqual(activity["status_display_type"] as? Int, 2)
        XCTAssertEqual(activity["details"] as? String, "Track title")
        XCTAssertEqual(activity["state"] as? String, "Track artist")
        let buttons = try XCTUnwrap(activity["buttons"] as? [[String: String]])
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons[0]["label"], "Play on YouTube Music")
        XCTAssertEqual(buttons[0]["url"], "https://music.youtube.com/search?q=Track%20title%20Track%20artist")
    }

    func testClearPayloadOmitsActivity() throws {
        let payload = try jsonObject(DiscordRPCPayload.clear(pid: 456, nonce: "clear-nonce"))
        let args = try XCTUnwrap(payload["args"] as? [String: Any])

        XCTAssertEqual(payload["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertEqual(payload["nonce"] as? String, "clear-nonce")
        XCTAssertEqual(args["pid"] as? Int, 456)
        XCTAssertNil(args["activity"])
    }

    func testPingBecomesPongWithoutChangingPayload() {
        let ping = DiscordIPCFrame(opcode: 3, payload: Data([1, 2, 3]))
        XCTAssertEqual(
            DiscordIPCCodec.pong(for: ping),
            DiscordIPCFrame(opcode: 4, payload: ping.payload)
        )
    }

    func testDesiredPresenceReducerAndElapsedDeduplication() {
        let playing = track(elapsedTime: 10, isPaused: false)
        let elapsedOnlyChange = track(elapsedTime: 90, isPaused: false)
        let paused = track(elapsedTime: 10, isPaused: true)

        XCTAssertEqual(DiscordPresenceService.desiredPresence(enabled: false, track: playing), .disabled)
        XCTAssertEqual(DiscordPresenceService.desiredPresence(enabled: true, track: nil), .clear)
        XCTAssertEqual(DiscordPresenceService.desiredPresence(enabled: true, track: paused), .clear)
        XCTAssertEqual(
            DiscordPresenceService.desiredPresence(enabled: true, track: playing),
            .activity(title: "Track title", artist: "Track artist")
        )
        XCTAssertEqual(
            DiscordPresenceService.desiredPresence(enabled: true, track: playing),
            DiscordPresenceService.desiredPresence(enabled: true, track: elapsedOnlyChange)
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func track(elapsedTime: TimeInterval, isPaused: Bool) -> Track {
        Track(
            title: "Track title",
            artist: "Track artist",
            syncOffsetKey: "key",
            duration: 180,
            elapsedTime: elapsedTime,
            isPaused: isPaused,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
    }
}
