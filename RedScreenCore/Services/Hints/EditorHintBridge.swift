import Foundation
import Observation

/// Turns the optional VS Code hint listener on and off and reports its status.
///
/// It runs only while the user has turned hints on and the Mac is awake, unlocked, and in this
/// user's session. Each start is a new session with a new key; stopping deletes the pairing file
/// and socket and forgets every hint. Logs record only counts and fixed events.
@MainActor
@Observable
public final class EditorHintBridge {
    public enum Status: Equatable, Sendable {
        case off
        /// Listening; no extension connected.
        case waiting
        case connected(Int)
        /// The listener could not start (for example, the directory is not private).
        case unavailable
    }

    public private(set) var status: Status = .off
    @ObservationIgnored public let store: EditorHintStore
    @ObservationIgnored private let configuration: HintBridgeServer.Configuration
    @ObservationIgnored private let logger: PrivacySafeLogger
    @ObservationIgnored private var server: HintBridgeServer?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connected = Set<UUID>()

    public init(configuration: HintBridgeServer.Configuration, store: EditorHintStore, logger: PrivacySafeLogger = PrivacySafeLogger()) {
        self.configuration = configuration
        self.store = store
        self.logger = logger
    }

    /// The pairing file the extension reads, while running.
    public var pairingURL: URL {
        configuration.directory.appendingPathComponent("rendezvous.json")
    }

    public var isRunning: Bool { server != nil }

    /// Starts a new session. Does nothing if already running.
    public func start() {
        guard server == nil else { return }
        generation += 1
        let current = generation
        let server = HintBridgeServer(configuration: configuration) { [weak self] event in
            // FIFO onto the main actor, so events apply in the order they happened.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, generation: current) }
            }
        }
        do {
            try server.start()
        } catch {
            status = .unavailable
            return
        }
        self.server = server
        store.beginSession(digestKey: server.digestKey)
        connected.removeAll()
        status = .waiting
        logger.record(.hintBridgeStarted)
    }

    /// Ends the session: disconnects peers, deletes the pairing file and socket, forgets hints.
    public func stop() {
        generation += 1
        let wasRunning = server != nil
        server?.stop()
        server = nil
        store.endSession()
        connected.removeAll()
        status = .off
        if wasRunning { logger.record(.hintBridgeStopped) }
    }

    private func handle(_ event: HintBridgeServer.Event, generation: Int) {
        // Events from a stopped or replaced session are ignored.
        guard generation == self.generation, server != nil else { return }
        store.apply(event)
        switch event {
        case .authenticated(let connection):
            connected.insert(connection)
            logger.record(.hintPeerAuthenticated)
        case .disconnected(let connection):
            connected.remove(connection)
        case .rejected:
            logger.record(.hintPeerRejected)
        case .hints, .cleared:
            break
        }
        status = connected.isEmpty ? .waiting : .connected(connected.count)
    }
}
