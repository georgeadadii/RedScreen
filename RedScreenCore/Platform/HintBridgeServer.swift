import Darwin
import Foundation
import Security

/// RedScreen's listener for the optional VS Code hint protocol.
///
/// - Listens on a Unix domain socket in a private directory (`0700`), with a pairing file
///   (`0600`) holding a fresh random session key. Nothing listens on the network.
/// - Accepts only peers running as the same user (`getpeereid`), at most four at once, each
///   authenticated by HMAC challenge–response before any hint is read.
/// - Validates every message (version, fields, tag, sequence, expiry, size, rate) and closes the
///   connection on the first violation. Accepted hints are delivered as events; nothing is
///   logged or written except the pairing file, which `stop()` deletes.
///
/// All socket state is confined to a private serial queue.
public final class HintBridgeServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var directory: URL
        public var sessionLifetime: TimeInterval
        public var messagesPerSecond: Double
        public var handshakeTimeout: TimeInterval
        public var now: @Sendable () -> Int64

        public init(
            directory: URL,
            sessionLifetime: TimeInterval = 8 * 60 * 60,
            messagesPerSecond: Double = 10,
            handshakeTimeout: TimeInterval = 3,
            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        ) {
            self.directory = directory
            self.sessionLifetime = sessionLifetime
            self.messagesPerSecond = messagesPerSecond
            self.handshakeTimeout = handshakeTimeout
            self.now = now
        }
    }

    public enum Event: Sendable {
        case authenticated(connection: UUID)
        case rejected(HintProtocolError)
        case hints(connection: UUID, doc: Data, expires: Int64, hints: [EditorHint])
        case cleared(connection: UUID, doc: Data)
        case disconnected(connection: UUID)
    }

    public enum StartError: Error, Equatable, Sendable {
        case insecureDirectory
        case pathTooLong
        case socketFailed
        case pairingFileFailed
    }

    public static let maximumConnections = 4

    public let socketURL: URL
    public let pairingURL: URL
    /// The session's digest key, for matching hints. Valid until `stop()`.
    public private(set) var digestKey = Data()

    private let configuration: Configuration
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.georgeadadii.RedScreen.hints")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    private var sessionKey = Data()
    private var sessionID = Data()

    public init(configuration: Configuration, onEvent: @escaping @Sendable (Event) -> Void) {
        self.configuration = configuration
        self.onEvent = onEvent
        socketURL = configuration.directory.appendingPathComponent("hints.sock")
        pairingURL = configuration.directory.appendingPathComponent("rendezvous.json")
    }

    deinit {
        stopOnQueue()
    }

    /// Creates the private directory, socket, and pairing file for a new session.
    public func start() throws {
        try queue.sync {
            stopOnQueue()
            try prepareDirectory()
            guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                throw StartError.pathTooLong
            }
            sessionKey = Self.randomBytes(HintProtocol.keyLength)
            sessionID = Self.randomBytes(HintProtocol.nonceLength)
            digestKey = HintProtocol.digestKey(key: sessionKey, session: sessionID)
            try listen()
            do {
                try writePairingFile()
            } catch {
                stopOnQueue()
                throw error
            }
        }
    }

    /// Closes every connection, removes the socket and pairing file, and forgets the session key.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    public var connectionCount: Int {
        queue.sync { connections.values.filter(\.isAuthenticated).count }
    }

    // MARK: - Setup

    private func prepareDirectory() throws {
        let path = configuration.directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw StartError.insecureDirectory }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw StartError.insecureDirectory
        }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 { throw StartError.insecureDirectory }
        // Remove leftovers from a session that ended without cleanup.
        unlink(socketURL.path)
        unlink(pairingURL.path)
    }

    private func listen() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.socketFailed }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else {
            close(descriptor)
            unlink(path)
            throw StartError.socketFailed
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    private func writePairingFile() throws {
        let expires = configuration.now() + Int64(configuration.sessionLifetime * 1000)
        let body: [String: Any] = [
            "protocol": HintProtocol.name,
            "version": HintProtocol.version,
            "socket": socketURL.path,
            "session": HintProtocol.base64url(sessionID),
            "key": HintProtocol.base64url(sessionKey),
            "expires": expires,
        ]
        guard let data = try? HintProtocol.canonicalJSON(body).data(using: .utf8) else {
            throw StartError.pairingFileFailed
        }
        // Written to a private temporary name, then renamed, so it never exists half-written or
        // with wider permissions.
        let staging = configuration.directory.appendingPathComponent(".rendezvous-\(UUID().uuidString)")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StartError.pairingFileFailed }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == data.count, rename(staging.path, pairingURL.path) == 0 else {
            unlink(staging.path)
            throw StartError.pairingFileFailed
        }
    }

    private func stopOnQueue() {
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 { close(listener) }
        listener = -1
        for connection in connections.values { connection.close(notify: false) }
        connections.removeAll()
        unlink(socketURL.path)
        unlink(pairingURL.path)
        sessionKey.resetBytes(in: 0..<sessionKey.count)
        digestKey.resetBytes(in: 0..<digestKey.count)
        sessionKey = Data()
        sessionID = Data()
        digestKey = Data()
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
                  connections.count < Self.maximumConnections else {
                close(descriptor)
                onEvent(.rejected(.authenticationFailed))
                continue
            }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(
                descriptor: descriptor, server: self, key: sessionKey, session: sessionID,
                configuration: configuration
            )
            connections[connection.id] = connection
            connection.start(on: queue)
        }
    }

    fileprivate func connectionEnded(_ connection: Connection, error: HintProtocolError?, wasAuthenticated: Bool) {
        connections.removeValue(forKey: connection.id)
        if let error { onEvent(.rejected(error)) }
        if wasAuthenticated { onEvent(.disconnected(connection: connection.id)) }
    }

    fileprivate func deliver(_ event: Event) {
        onEvent(event)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "System random generator failed")
        return bytes
    }
}

/// One peer connection. Confined to the server's queue.
private final class Connection {
    let id = UUID()
    private let descriptor: Int32
    private weak var server: HintBridgeServer?
    private let key: Data
    private let session: Data
    private let configuration: HintBridgeServer.Configuration
    private var source: DispatchSourceRead?
    private var timeout: DispatchSourceTimer?
    private var decoder = HintFrameDecoder()
    private var guardSequence = HintSequenceGuard()
    private var clientNonce: Data?
    private var serverNonce = HintBridgeServer.randomBytes(HintProtocol.nonceLength)
    private var receiveKey: Data?
    private var sendKey: Data?
    private var sendSequence: Int64 = 0
    private var tokens: Double
    private var refilledAt: Int64
    private var closed = false

    var isAuthenticated: Bool { receiveKey != nil }

    init(descriptor: Int32, server: HintBridgeServer, key: Data, session: Data, configuration: HintBridgeServer.Configuration) {
        self.descriptor = descriptor
        self.server = server
        self.key = key
        self.session = session
        self.configuration = configuration
        tokens = configuration.messagesPerSecond * 2
        refilledAt = configuration.now()
    }

    func start(on queue: DispatchQueue) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.handshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isAuthenticated else { return }
            self.fail(.authenticationFailed)
        }
        timer.resume()
        timeout = timer
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !closed {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                do {
                    for frame in try decoder.push(Data(buffer[0..<count])) {
                        try handle(frame)
                        if closed { return }
                    }
                } catch let error as HintProtocolError {
                    fail(error)
                } catch {
                    fail(.malformedMessage)
                }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                close(notify: true)
                return
            } else {
                return
            }
        }
    }

    private func handle(_ frame: Data) throws {
        guard let clientNonce else {
            let hello = try HintProtocol.parseFrame(frame, expected: ["hello"])
            guard try HintProtocol.decodeBase64url(hello["session"], length: HintProtocol.nonceLength) == session else {
                throw HintProtocolError.authenticationFailed
            }
            let nonce = try HintProtocol.decodeBase64url(hello["nonce"], length: HintProtocol.nonceLength)
            self.clientNonce = nonce
            try send(Data(try HintProtocol.canonicalJSON([
                "t": "challenge", "v": HintProtocol.version, "nonce": HintProtocol.base64url(serverNonce),
                "proof": HintProtocol.base64url(HintProtocol.serverProof(
                    key: key, session: session, clientNonce: nonce, serverNonce: serverNonce)),
            ]).utf8))
            return
        }
        guard let receiveKey else {
            let auth = try HintProtocol.parseFrame(frame, expected: ["auth"])
            let expected = HintProtocol.clientProof(key: key, session: session, clientNonce: clientNonce, serverNonce: serverNonce)
            let proof = try HintProtocol.decodeBase64url(auth["proof"], length: 32)
            guard Self.constantTimeEqual(proof, expected) else { throw HintProtocolError.authenticationFailed }
            self.receiveKey = HintProtocol.connectionKey(key: key, session: session, clientNonce: clientNonce,
                                                         serverNonce: serverNonce, direction: .clientToServer)
            sendKey = HintProtocol.connectionKey(key: key, session: session, clientNonce: clientNonce,
                                                 serverNonce: serverNonce, direction: .serverToClient)
            timeout?.cancel()
            try sendSealed(["t": "ready", "v": HintProtocol.version])
            server?.deliver(.authenticated(connection: id))
            return
        }
        guard takeToken() else { throw HintProtocolError.rateLimited }
        let body = try HintProtocol.verifyTag(key: receiveKey, message: HintProtocol.parseFrame(frame, expected: ["hints", "clear"]))
        try guardSequence.accept(body["seq"])
        if body["t"] as? String == "hints" {
            let validated = try HintProtocol.validateHints(body, now: configuration.now())
            server?.deliver(.hints(connection: id, doc: validated.doc, expires: validated.expires, hints: validated.hints))
            try sendSealed(["t": "ack", "v": HintProtocol.version, "accepted": validated.hints.count])
        } else {
            let doc = try HintProtocol.decodeBase64url(body["doc"], length: HintProtocol.nonceLength)
            server?.deliver(.cleared(connection: id, doc: doc))
        }
    }

    private func takeToken() -> Bool {
        let now = configuration.now()
        let burst = configuration.messagesPerSecond * 2
        tokens = min(burst, tokens + Double(now - refilledAt) / 1000 * configuration.messagesPerSecond)
        refilledAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    private func sendSealed(_ body: [String: Any]) throws {
        guard let sendKey else { throw HintProtocolError.unexpectedMessage }
        var message = body
        message["seq"] = sendSequence
        sendSequence += 1
        try send(try HintProtocol.seal(key: sendKey, body: message))
    }

    private func send(_ payload: Data) throws {
        let frame = try HintFrameDecoder.encode(payload)
        let written = frame.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == frame.count else { throw HintProtocolError.malformedMessage }
    }

    private func fail(_ error: HintProtocolError) {
        guard !closed else { return }
        closed = true
        teardown()
        server?.connectionEnded(self, error: error, wasAuthenticated: receiveKey != nil)
        wipeKeys()
    }

    func close(notify: Bool) {
        guard !closed else { return }
        closed = true
        teardown()
        if notify { server?.connectionEnded(self, error: nil, wasAuthenticated: receiveKey != nil) }
        wipeKeys()
    }

    private func teardown() {
        timeout?.cancel()
        source?.cancel()
        Darwin.close(descriptor)
    }

    private func wipeKeys() {
        if var key = receiveKey { key.resetBytes(in: 0..<key.count) }
        if var key = sendKey { key.resetBytes(in: 0..<key.count) }
        receiveKey = nil
        sendKey = nil
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
