import Darwin
import Foundation
import XCTest

@testable import RedScreenCore

/// RED-13: the native listener authenticates peers, validates every message, and fails closed.
final class HintBridgeServerTests: XCTestCase {
    private var directory: URL!
    private var server: HintBridgeServer!
    private let events = EventLog()

    override func setUpWithError() throws {
        // A short path: Unix socket paths are limited to 103 bytes.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("rsh-\(UUID().uuidString.prefix(8))")
        server = makeServer()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeServer(rate: Double = 10, timeout: TimeInterval = 3, lifetime: TimeInterval = 600) -> HintBridgeServer {
        let log = events
        return HintBridgeServer(configuration: .init(
            directory: directory, sessionLifetime: lifetime, messagesPerSecond: rate, handshakeTimeout: timeout
        )) { log.append($0) }
    }

    // MARK: - Files

    func testPairingFileAndSocketArePrivateAndRemovedOnStop() throws {
        XCTAssertEqual(try permissions(directory.path), 0o700)
        XCTAssertEqual(try permissions(server.socketURL.path), 0o600)
        XCTAssertEqual(try permissions(server.pairingURL.path), 0o600)
        var info = stat()
        XCTAssertEqual(lstat(server.socketURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)

        let pairing = try HintTestClient.pairing(at: server.pairingURL)
        XCTAssertEqual(pairing.socket, server.socketURL.path)
        XCTAssertEqual(server.digestKey, HintProtocol.digestKey(key: pairing.key, session: pairing.session))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["hints.sock", "rendezvous.json"])

        server.stop()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(server.digestKey.isEmpty, "The session's keys are forgotten")
    }

    func testEachStartIsANewSessionAndOldKeysStopWorking() throws {
        let first = try HintTestClient.pairing(at: server.pairingURL)
        server.stop()
        try server.start()
        let second = try HintTestClient.pairing(at: server.pairingURL)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertNotEqual(first.session, second.session)
        let stale = try HintTestClient(pairing: HintTestClient.Pairing(socket: second.socket, session: first.session, key: first.key))
        XCTAssertThrowsError(try stale.handshake())
        waitFor { self.events.rejections.contains(.authenticationFailed) }
    }

    func testAnInsecureDirectoryIsRefused() throws {
        server.stop()
        let other = URL(fileURLWithPath: "/tmp").appendingPathComponent("rsh-link-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: other) }
        let linked = HintBridgeServer(configuration: .init(directory: other)) { _ in }
        XCTAssertThrowsError(try linked.start()) {
            XCTAssertEqual($0 as? HintBridgeServer.StartError, .insecureDirectory)
        }
    }

    // MARK: - Protocol

    func testAuthenticatedClientDeliversHintsAndClears() throws {
        let client = try HintTestClient(pairing: HintTestClient.pairing(at: server.pairingURL))
        try client.handshake()
        waitFor { self.events.authenticated == 1 }
        XCTAssertEqual(server.connectionCount, 1)

        let doc = Data(repeating: 9, count: 16)
        let ack = try client.sendHints(doc: doc, hints: [("assignment.env", 95, "RSFAKE-pg-7d1c9a42")])
        XCTAssertEqual(ack["accepted"] as? Int, 1)
        waitFor { self.events.hints.count == 1 }
        let delivered = try XCTUnwrap(events.hints.first)
        XCTAssertEqual(delivered.doc, doc)
        XCTAssertEqual(delivered.hints.map(\.rule), ["assignment.env"])
        XCTAssertEqual(delivered.hints[0].digest,
                       HintProtocol.digest(digestKey: server.digestKey, rule: "assignment.env", value: "RSFAKE-pg-7d1c9a42"))

        try client.sendClear(doc: doc)
        waitFor { self.events.cleared == 1 }
        client.close()
        waitFor { self.events.disconnected == 1 }
    }

    func testSpoofedClientAndWrongSessionAreRefused() throws {
        let pairing = try HintTestClient.pairing(at: server.pairingURL)
        let spoofed = try HintTestClient(pairing: .init(socket: pairing.socket, session: pairing.session, key: Data(repeating: 1, count: 32)))
        // The server's proof does not verify under the wrong key, so the client stops; a client
        // that answers anyway with a bad proof is refused by the server.
        XCTAssertThrowsError(try spoofed.handshake())
        let forced = try HintTestClient(pairing: .init(socket: pairing.socket, session: pairing.session, key: Data(repeating: 1, count: 32)))
        try forced.handshake(skipServerProofCheck: true, expectReady: false)
        waitFor { self.events.rejections.filter { $0 == .authenticationFailed }.count >= 1 }

        let wrongSession = try HintTestClient(pairing: .init(socket: pairing.socket, session: Data(repeating: 2, count: 16), key: pairing.key))
        XCTAssertThrowsError(try wrongSession.handshake())
        waitFor { self.events.rejections.filter { $0 == .authenticationFailed }.count >= 2 }
        XCTAssertEqual(events.authenticated, 0)
        XCTAssertEqual(events.hints.count, 0)
    }

    func testReplayTamperingAndCrossConnectionFramesAreRejected() throws {
        let pairing = try HintTestClient.pairing(at: server.pairingURL)
        let first = try HintTestClient(pairing: pairing)
        try first.handshake()
        let frame = try first.hintsFrame(sequence: 0, doc: Data(repeating: 3, count: 16), hints: [])
        try first.sendRaw(frame)
        _ = try first.readMessage()
        try first.sendRaw(frame)  // Exact replay on the same connection.
        waitFor { self.events.rejections.contains(.replayedOrOutOfOrder) }

        let second = try HintTestClient(pairing: pairing)
        try second.handshake()
        try second.sendRaw(frame)  // A frame from another connection.
        waitFor { self.events.rejections.filter { $0 == .authenticationFailed }.count == 1 }

        let third = try HintTestClient(pairing: pairing)
        try third.handshake()
        var tampered = try XCTUnwrap(JSONSerialization.jsonObject(with: try third.hintsFrame(sequence: 0, doc: Data(repeating: 4, count: 16), hints: [])) as? [String: Any])
        tampered["expires"] = (tampered["expires"] as? Int ?? 0) + 1
        try third.sendRaw(Data(try HintProtocol.canonicalJSON(tampered).utf8))
        waitFor { self.events.rejections.filter { $0 == .authenticationFailed }.count == 2 }
        XCTAssertEqual(events.hints.count, 1, "Only the first, valid message was delivered")
    }

    func testVersionMismatchOversizeExpiryAndUnauthenticatedHintsFailClosed() throws {
        let pairing = try HintTestClient.pairing(at: server.pairingURL)
        let version = try HintTestClient(pairing: pairing)
        try version.sendRaw(Data(#"{"t":"hello","v":2,"session":"x","nonce":"y"}"#.utf8))
        waitFor { self.events.rejections.contains(.incompatibleVersion) }

        let oversized = try HintTestClient(pairing: pairing)
        try oversized.sendBytes(Data([0, 0, 0x40, 0x01]))
        waitFor { self.events.rejections.contains(.oversizedMessage) }

        let early = try HintTestClient(pairing: pairing)
        try early.sendRaw(try early.hintsFrame(sequence: 0, doc: Data(repeating: 5, count: 16), hints: [], key: Data(repeating: 0, count: 32)))
        waitFor { self.events.rejections.contains(.unexpectedMessage) }

        let stale = try HintTestClient(pairing: pairing)
        try stale.handshake()
        let past = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        try stale.sendRaw(try stale.hintsFrame(sequence: 0, doc: Data(repeating: 6, count: 16), hints: [], sent: past))
        waitFor { self.events.rejections.contains(.expired) }
        XCTAssertEqual(events.hints.count, 0)
    }

    func testFloodingConnectionIsClosed() throws {
        server.stop()
        server = makeServer(rate: 2)
        try server.start()
        let client = try HintTestClient(pairing: HintTestClient.pairing(at: server.pairingURL))
        try client.handshake()
        for sequence in 0..<10 {
            try? client.sendRaw(try client.hintsFrame(sequence: Int64(sequence), doc: Data(repeating: 1, count: 16), hints: []))
        }
        waitFor { self.events.rejections.contains(.rateLimited) }
        XCTAssertLessThanOrEqual(events.hints.count, 4)
    }

    func testSilentPeerIsDisconnectedAfterTheHandshakeTimeout() throws {
        server.stop()
        server = makeServer(timeout: 0.2)
        try server.start()
        let client = try HintTestClient(pairing: HintTestClient.pairing(at: server.pairingURL))
        _ = client
        waitFor { self.events.rejections.contains(.authenticationFailed) }
    }

    // MARK: - Helpers

    private func permissions(_ path: String) throws -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return info.st_mode & 0o777
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

/// Thread-safe record of server events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HintBridgeServer.Event] = []

    func append(_ event: HintBridgeServer.Event) { lock.withLock { stored.append(event) } }
    private var all: [HintBridgeServer.Event] { lock.withLock { stored } }

    var authenticated: Int { all.filter { if case .authenticated = $0 { true } else { false } }.count }
    var disconnected: Int { all.filter { if case .disconnected = $0 { true } else { false } }.count }
    var cleared: Int { all.filter { if case .cleared = $0 { true } else { false } }.count }
    var rejections: [HintProtocolError] { all.compactMap { if case .rejected(let error) = $0 { error } else { nil } } }
    var hints: [(doc: Data, hints: [EditorHint])] {
        all.compactMap { if case .hints(_, let doc, _, let hints) = $0 { (doc, hints) } else { nil } }
    }
}

/// A minimal protocol client for tests: the extension's behaviour, written in Swift.
final class HintTestClient {
    struct Pairing {
        let socket: String
        let session: Data
        let key: Data
    }

    private let descriptor: Int32
    private let pairing: Pairing
    private var decoder = HintFrameDecoder()
    private(set) var sendKey: Data?
    private var receiveKey: Data?
    private var sequence: Int64 = 0

    static func pairing(at url: URL) throws -> Pairing {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Pairing(
            socket: try XCTUnwrap(object["socket"] as? String),
            session: try HintProtocol.decodeBase64url(object["session"], length: 16),
            key: try HintProtocol.decodeBase64url(object["key"], length: 32)
        )
    }

    init(pairing: Pairing) throws {
        self.pairing = pairing
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pairing.socket.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw CocoaError(.fileReadNoPermission) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { Darwin.close(descriptor) }

    func close() { Darwin.shutdown(descriptor, SHUT_RDWR) }

    func handshake(skipServerProofCheck: Bool = false, expectReady: Bool = true) throws {
        let clientNonce = HintBridgeServer.randomBytes(16)
        try sendRaw(Data(try HintProtocol.canonicalJSON([
            "t": "hello", "v": 1, "session": HintProtocol.base64url(pairing.session), "nonce": HintProtocol.base64url(clientNonce),
        ]).utf8))
        let challenge = try readMessage()
        let serverNonce = try HintProtocol.decodeBase64url(challenge["nonce"], length: 16)
        let proof = try HintProtocol.decodeBase64url(challenge["proof"], length: 32)
        if !skipServerProofCheck,
           proof != HintProtocol.serverProof(key: pairing.key, session: pairing.session, clientNonce: clientNonce, serverNonce: serverNonce) {
            throw HintProtocolError.authenticationFailed
        }
        try sendRaw(Data(try HintProtocol.canonicalJSON([
            "t": "auth", "v": 1,
            "proof": HintProtocol.base64url(HintProtocol.clientProof(key: pairing.key, session: pairing.session,
                                                                     clientNonce: clientNonce, serverNonce: serverNonce)),
        ]).utf8))
        sendKey = HintProtocol.connectionKey(key: pairing.key, session: pairing.session, clientNonce: clientNonce,
                                             serverNonce: serverNonce, direction: .clientToServer)
        receiveKey = HintProtocol.connectionKey(key: pairing.key, session: pairing.session, clientNonce: clientNonce,
                                                serverNonce: serverNonce, direction: .serverToClient)
        guard expectReady else { return }
        let ready = try HintProtocol.verifyTag(key: receiveKey!, message: readMessage())
        guard ready["t"] as? String == "ready" else { throw HintProtocolError.unexpectedMessage }
    }

    func hintsFrame(
        sequence: Int64, doc: Data, hints: [(String, Int, String)], sent: Int64? = nil, key: Data? = nil
    ) throws -> Data {
        let now = sent ?? Int64(Date().timeIntervalSince1970 * 1000)
        let sessionDigestKey = HintProtocol.digestKey(key: pairing.key, session: pairing.session)
        let entries: [[String: Any]] = hints.map { rule, confidence, value in
            ["rule": rule, "conf": confidence,
             "digest": HintProtocol.base64url(HintProtocol.digest(digestKey: sessionDigestKey, rule: rule, value: value))]
        }
        return try HintProtocol.seal(key: key ?? sendKey ?? Data(count: 32), body: [
            "t": "hints", "v": 1, "seq": sequence, "sent": now, "expires": now + 10_000,
            "doc": HintProtocol.base64url(doc), "hints": entries,
        ])
    }

    @discardableResult
    func sendHints(doc: Data, hints: [(String, Int, String)]) throws -> [String: Any] {
        try sendRaw(try hintsFrame(sequence: sequence, doc: doc, hints: hints))
        sequence += 1
        return try HintProtocol.verifyTag(key: receiveKey!, message: readMessage())
    }

    func sendClear(doc: Data) throws {
        try sendRaw(try HintProtocol.seal(key: sendKey!, body: ["t": "clear", "v": 1, "seq": sequence, "doc": HintProtocol.base64url(doc)]))
        sequence += 1
    }

    func sendRaw(_ payload: Data) throws {
        try sendBytes(try HintFrameDecoder.encode(payload))
    }

    func sendBytes(_ bytes: Data) throws {
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw CocoaError(.fileWriteUnknown) }
    }

    func readMessage() throws -> [String: Any] {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            if let frame = try decoder.push(Data(buffer[0..<count])).first {
                return try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            }
        }
    }
}
