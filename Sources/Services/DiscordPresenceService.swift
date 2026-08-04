import Combine
import Darwin
import Foundation

struct DiscordIPCFrame: Equatable {
    let opcode: UInt32
    let payload: Data
}

enum DiscordIPCCodec {
    static let maximumPayloadLength = 65_528

    enum CodecError: Error, Equatable {
        case payloadTooLarge(Int)
    }

    static func encode(_ frame: DiscordIPCFrame) throws -> Data {
        guard frame.payload.count <= maximumPayloadLength else {
            throw CodecError.payloadTooLarge(frame.payload.count)
        }

        var data = Data()
        appendLittleEndian(frame.opcode, to: &data)
        appendLittleEndian(UInt32(frame.payload.count), to: &data)
        data.append(frame.payload)
        return data
    }

    static func decodeAvailable(from buffer: inout Data) throws -> [DiscordIPCFrame] {
        var frames: [DiscordIPCFrame] = []
        var consumed = 0

        while buffer.count - consumed >= 8 {
            let opcode = littleEndianUInt32(in: buffer, at: consumed)
            let length = Int(littleEndianUInt32(in: buffer, at: consumed + 4))
            guard length <= maximumPayloadLength else {
                throw CodecError.payloadTooLarge(length)
            }
            guard buffer.count - consumed >= 8 + length else { break }

            let payloadStart = consumed + 8
            frames.append(DiscordIPCFrame(
                opcode: opcode,
                payload: buffer.subdata(in: payloadStart..<(payloadStart + length))
            ))
            consumed += 8 + length
        }

        if consumed > 0 {
            buffer.removeSubrange(0..<consumed)
        }
        return frames
    }

    static func pong(for ping: DiscordIPCFrame) -> DiscordIPCFrame? {
        guard ping.opcode == 3 else { return nil }
        return DiscordIPCFrame(opcode: 4, payload: ping.payload)
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }
}

enum DiscordRPCPayload {
    static func handshake(clientID: String) throws -> Data {
        try json(["v": 1, "client_id": clientID])
    }

    static func activity(pid: Int32, title: String, artist: String, artworkURL: URL?, nonce: String) throws -> Data {
        var activity: [String: Any] = [
            "type": 2,
            "status_display_type": 2,
            "details": title,
            "state": artist
        ]
        if let url = youtubeMusicSearchURL(title: title, artist: artist) {
            activity["buttons"] = [["label": "Play on YouTube Music", "url": url]]
        }
        if let artworkURL,
           artworkURL.scheme?.lowercased() == "https",
           artworkURL.host != nil {
            activity["assets"] = ["large_image": artworkURL.absoluteString]
        }
        return try json([
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": pid,
                "activity": activity
            ],
            "nonce": nonce
        ])
    }

    static func youtubeMusicSearchURL(title: String, artist: String) -> String? {
        var components = URLComponents(string: "https://music.youtube.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(title) \(artist)")]
        return components?.url?.absoluteString
    }

    static func clear(pid: Int32, nonce: String) throws -> Data {
        try json([
            "cmd": "SET_ACTIVITY",
            "args": ["pid": pid],
            "nonce": nonce
        ])
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

final class DiscordPresenceService {
    static let shared = DiscordPresenceService()

    enum DesiredPresence: Equatable {
        case disabled
        case clear
        case activity(title: String, artist: String, artworkURL: URL?)
    }

    private enum PendingCommand {
        case activity
        case clear
    }

    private let queue = DispatchQueue(label: "com.playerstudio.discord-presence")
    private let lifecycleLock = NSLock()
    private var started = false
    private var subscription: AnyCancellable?

    private var clientID: String?
    private var desired: DesiredPresence = .disabled
    private var socketFD: Int32 = -1
    private var connecting = false
    private var ready = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readBuffer = Data()
    private var writeBuffer = Data()
    private var pendingCommands: [String: PendingCommand] = [:]
    private var closeAfterWrite = false
    private var retryWorkItem: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.5

    private init() {}

    static func desiredPresence(enabled: Bool, track: Track?) -> DesiredPresence {
        guard enabled else { return .disabled }
        guard let track, !track.isPaused else { return .clear }
        return .activity(title: track.title, artist: track.artist, artworkURL: track.artworkURL)
    }

    func start() {
        lifecycleLock.lock()
        guard !started else {
            lifecycleLock.unlock()
            return
        }
        started = true
        lifecycleLock.unlock()

        let configuredID = Bundle.main.object(forInfoDictionaryKey: "DiscordClientID") as? String
        if let configuredID,
           !configuredID.isEmpty,
           configuredID.allSatisfy(\.isNumber) {
            clientID = configuredID
        } else {
            Logger.error("Discord presence configuration error: invalid DiscordClientID.")
        }

        subscription = AppSettings.shared.$discordPresenceEnabled
            .combineLatest(PlaybackEngine.shared.$currentTrack)
            .map(Self.desiredPresence)
            .removeDuplicates()
            .sink { [weak self] desired in
                self?.queue.async {
                    self?.apply(desired)
                }
            }
    }

    func stop() {
        lifecycleLock.lock()
        guard started else {
            lifecycleLock.unlock()
            return
        }
        started = false
        lifecycleLock.unlock()

        subscription?.cancel()
        subscription = nil
        queue.sync {
            desired = .disabled
            cancelRetry()
            if ready {
                try? sendClear()
                flushWrites()
            }
            disconnect(shouldRetry: false, log: false)
        }
    }

    private func apply(_ newDesired: DesiredPresence) {
        desired = newDesired

        switch newDesired {
        case .disabled:
            cancelRetry()
            pendingCommands.removeAll()
            if ready {
                do {
                    try sendClear()
                    closeAfterWrite = true
                    flushWrites()
                } catch {
                    disconnect(shouldRetry: false, log: false)
                }
            } else {
                disconnect(shouldRetry: false, log: false)
            }
        case .clear:
            cancelRetry()
            if ready {
                try? sendClear()
            } else {
                connectIfNeeded()
            }
        case .activity:
            if ready {
                try? sendDesired()
            } else {
                connectIfNeeded()
            }
        }
    }

    private func connectIfNeeded() {
        guard clientID != nil, socketFD < 0, retryWorkItem == nil else { return }

        let environment = ProcessInfo.processInfo.environment
        let directory = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
            .compactMap { environment[$0] }
            .first { !$0.isEmpty } ?? "/tmp"

        for index in 0...9 {
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("discord-ipc-\(index)").path
            if openSocket(at: path) { return }
        }

        scheduleRetryIfNeeded()
    }

    private func openSocket(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            return false
        }

        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0 else {
            Darwin.close(fd)
            return false
        }

        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < pathCapacity else {
            Darwin.close(fd)
            return false
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: pathCapacity) { destination in
                for (offset, byte) in pathBytes.enumerated() {
                    destination[offset] = byte
                }
                destination[pathBytes.count] = 0
            }
        }

        let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }

        guard result == 0 || errno == EINPROGRESS else {
            Darwin.close(fd)
            return false
        }

        socketFD = fd
        connecting = result != 0
        if connecting {
            enableWriteSource()
        } else {
            connectionEstablished()
        }
        return true
    }

    private func connectionEstablished() {
        connecting = false
        installReadSource()
        do {
            guard let clientID else { return }
            try enqueue(DiscordIPCFrame(opcode: 0, payload: DiscordRPCPayload.handshake(clientID: clientID)))
        } catch {
            disconnect(shouldRetry: true, log: true)
        }
    }

    private func finishConnection() {
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: socketError))
        guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
              socketError == 0 else {
            disconnect(shouldRetry: true, log: false)
            return
        }
        connectionEstablished()
    }

    private func installReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
    }

    private func enableWriteSource() {
        guard writeSource == nil, socketFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.writeAvailable() }
        source.resume()
        writeSource = source
    }

    private func disableWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 8_192)

        while socketFD >= 0 {
            let count = Darwin.recv(socketFD, &bytes, bytes.count, 0)
            if count > 0 {
                readBuffer.append(bytes, count: count)
                do {
                    for frame in try DiscordIPCCodec.decodeAvailable(from: &readBuffer) {
                        handle(frame)
                    }
                } catch {
                    disconnect(shouldRetry: true, log: true)
                    return
                }
            } else if count == 0 {
                disconnect(shouldRetry: true, log: true)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                disconnect(shouldRetry: true, log: true)
                return
            }
        }
    }

    private func handle(_ frame: DiscordIPCFrame) {
        switch frame.opcode {
        case 1:
            handleJSON(frame.payload)
        case 2:
            disconnect(shouldRetry: true, log: true)
        case 3:
            if let pong = DiscordIPCCodec.pong(for: frame) {
                try? enqueue(pong)
            }
        default:
            break
        }
    }

    private func handleJSON(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }

        if object["cmd"] as? String == "DISPATCH", object["evt"] as? String == "READY" {
            ready = true
            retryDelay = 0.5
            cancelRetry()
            Logger.info("Discord IPC ready.")
            try? sendDesired()
            return
        }

        if object["evt"] as? String == "ERROR" {
            let data = object["data"] as? [String: Any]
            let code = (data?["code"] as? NSNumber)?.intValue ?? 0
            let message = data?["message"] as? String ?? "Unknown error"
            Logger.error("Discord RPC error \(code): \(message)")
            return
        }

        guard let nonce = object["nonce"] as? String,
              let command = pendingCommands.removeValue(forKey: nonce) else { return }
        switch command {
        case .activity:
            Logger.info("Discord presence updated.")
        case .clear:
            Logger.info("Discord presence cleared.")
        }
    }

    private func sendDesired() throws {
        switch desired {
        case .disabled, .clear:
            try sendClear()
        case let .activity(title, artist, artworkURL):
            let nonce = UUID().uuidString
            pendingCommands[nonce] = .activity
            try enqueue(DiscordIPCFrame(
                opcode: 1,
                payload: DiscordRPCPayload.activity(
                    pid: getpid(),
                    title: title,
                    artist: artist,
                    artworkURL: artworkURL,
                    nonce: nonce
                )
            ))
        }
    }

    private func sendClear() throws {
        let nonce = UUID().uuidString
        pendingCommands[nonce] = .clear
        try enqueue(DiscordIPCFrame(
            opcode: 1,
            payload: DiscordRPCPayload.clear(pid: getpid(), nonce: nonce)
        ))
    }

    private func enqueue(_ frame: DiscordIPCFrame) throws {
        writeBuffer.append(try DiscordIPCCodec.encode(frame))
        flushWrites()
    }

    private func flushWrites() {
        guard socketFD >= 0, !connecting else {
            enableWriteSource()
            return
        }

        while !writeBuffer.isEmpty {
            let sent = writeBuffer.withUnsafeBytes { bytes in
                Darwin.send(socketFD, bytes.baseAddress, bytes.count, 0)
            }
            if sent > 0 {
                writeBuffer.removeFirst(sent)
            } else if sent < 0, errno == EINTR {
                continue
            } else if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                enableWriteSource()
                return
            } else {
                disconnect(shouldRetry: true, log: true)
                return
            }
        }

        disableWriteSource()
        if closeAfterWrite {
            disconnect(shouldRetry: false, log: false)
        }
    }

    private func writeAvailable() {
        if connecting {
            finishConnection()
        }
        if socketFD >= 0, !connecting {
            flushWrites()
        }
    }

    private func disconnect(shouldRetry: Bool, log: Bool) {
        let wasConnected = socketFD >= 0
        readSource?.cancel()
        readSource = nil
        disableWriteSource()
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        socketFD = -1
        connecting = false
        ready = false
        readBuffer.removeAll(keepingCapacity: true)
        writeBuffer.removeAll(keepingCapacity: true)
        pendingCommands.removeAll()
        closeAfterWrite = false

        if log, wasConnected {
            Logger.error("Discord IPC disconnected.")
        }
        if shouldRetry {
            scheduleRetryIfNeeded()
        }
    }

    private func scheduleRetryIfNeeded() {
        guard case .activity = desired, retryWorkItem == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            retryWorkItem = nil
            connectIfNeeded()
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }
}
