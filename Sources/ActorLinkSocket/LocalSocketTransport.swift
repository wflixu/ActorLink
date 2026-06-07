import Foundation
import ActorLink
import OSLog

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Error Helpers

/// Returns a human-readable string for the current `errno`.
private func errnoString() -> String {
    String(cString: strerror(errno))
}

// MARK: - Connection Gate

/// Async gate that signals when a socket connection is established.
///
/// Both `send` and `receive` await this gate, so they suspend until
/// the background `accept()` (for server) or `connect()` (for client) completes.
private actor ConnectionGate {
    private var fd: Int32 = -1
    private var waiter: CheckedContinuation<Int32, Never>?

    func open(_ clientFD: Int32) {
        fd = clientFD
        waiter?.resume(returning: clientFD)
        waiter = nil
    }

    func wait() async -> Int32 {
        if fd >= 0 { return fd }
        return await withCheckedContinuation { waiter = $0 }
    }
}

// MARK: - Transport State

private struct TransportState: Sendable {
    var socketFD: Int32 = -1
    var isRunning = false
    var socketPath: String = ""

    mutating func cleanup() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        if isRunning, !socketPath.isEmpty {
            unlink(socketPath)
        }
        isRunning = false
    }
}

// MARK: - LocalSocketTransport

/// A transport that communicates over a Unix Domain Socket.
///
/// ## Framing
/// Messages use length-prefixed framing:
/// - 4 bytes: payload length as big-endian `UInt32`
/// - N bytes: JSON-encoded `Envelope`
///
/// ## Lifecycle
/// - Server: `start()` creates the socket, binds, and listens. A background task
///   accepts the first client connection. `send()` and `receive()` suspend until
///   the connection is established.
/// - Client: `start()` creates the socket and connects. `start()` returns once
///   the connection is ready.
///
/// ## Sandbox / App Group
/// For App Extension scenarios (sandbox), the socket file **must** be placed in an
/// App Group shared container. Use the ``appGroup(_:socketName:isServer:)`` factory
/// to create a sandbox-safe transport automatically:
///
/// ```swift
/// let transport = try LocalSocketTransport.appGroup(
///     "group.com.example",
///     isServer: true
/// )
/// ```
///
/// ## Thread Safety
/// The class uses `OSAllocatedUnfairLock` for FD access and an internal
/// `ConnectionGate` actor for async connection readiness signaling.
public final class LocalSocketTransport: @unchecked Sendable, ActorTransport {
    private let lock = OSAllocatedUnfairLock(initialState: TransportState())
    private let gate = ConnectionGate()
    private let socketPath: String
    private let isServer: Bool
    private let logger = Logger(subsystem: "com.actorlink", category: "socket")

    // MARK: - Factory

    /// Create a transport in an App Group shared container (sandbox-safe).
    ///
    /// This is the recommended way to create a transport for App Extension
    /// communication. The socket file is placed in the App Group container
    /// so both the host app and the extension can access it.
    ///
    /// - Parameters:
    ///   - appGroup: The App Group identifier (e.g. `"group.com.example"`).
    ///   - socketName: Socket file name (default `"actorlink.sock"`).
    ///   - isServer: `true` to listen/accept, `false` to connect.
    /// - Throws: `ActorLinkError.transportError` if the App Group is not
    ///   available (e.g. not configured in entitlements).
    public static func appGroup(
        _ appGroup: String,
        socketName: String = "actorlink.sock",
        isServer: Bool
    ) throws -> LocalSocketTransport {
        guard
            let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else {
            throw ActorLinkError.transportError(
                "App Group '\(appGroup)' not found. "
                    + "Add the App Groups capability to your entitlements.")
        }
        return LocalSocketTransport(
            socketPath: container.appendingPathComponent(socketName).path,
            isServer: isServer
        )
    }

    // MARK: - Init

    /// Create a transport using a Unix Domain Socket.
    ///
    /// For sandboxed apps (App Extensions), use ``appGroup(_:socketName:isServer:)``
    /// instead to ensure the socket is placed in a shared container.
    ///
    /// - Parameters:
    ///   - socketPath: Path for the socket file.
    ///   - isServer: `true` to listen/accept (server), `false` to connect (client).
    public init(socketPath: String, isServer: Bool) {
        self.socketPath = socketPath
        self.isServer = isServer
    }

    deinit {
        lock.withLock { $0.cleanup() }
    }

    // MARK: - ActorTransport

    public func start(id: String) async throws {
        let fd = try createSocket()

        if isServer {
            try bindSocket(fd)
            listen(fd, 1)

            lock.withLock { state in
                state.socketFD = fd
                state.socketPath = socketPath
                state.isRunning = true
            }

            logger.debug("Listening on \(self.socketPath)")

            // Accept the first client on a background thread —
            // must not block the cooperative thread pool.
            Task.detached { [weak self, fd] in
                guard let self else { return }
                let clientFD = accept(fd, nil, nil)
                guard clientFD >= 0 else {
                    self.logger.error(
                        "Accept failed: \(errnoString())")
                    return
                }
                self.lock.withLock { state in
                    state.socketFD = clientFD
                }
                self.logger.debug("Client connected")
                await self.gate.open(clientFD)
            }
        } else {
            try connectSocket(fd)
            lock.withLock { state in
                state.socketFD = fd
                state.isRunning = true
            }
            logger.debug("Connected to \(self.socketPath)")
            await gate.open(fd)
        }
    }

    public func stop() async throws {
        lock.withLock { $0.cleanup() }
        logger.debug("Transport stopped")
    }

    public func send(_ envelope: Envelope) async throws {
        let data = try JSONEncoder().encode(envelope)
        let fd = await gate.wait()
        guard fd >= 0 else {
            throw ActorLinkError.transportError("No connection available")
        }
        try writeLengthPrefixed(data, to: fd)
    }

    public func receive() -> AsyncThrowingStream<Envelope, any Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let fd = await self.gate.wait()
                guard fd >= 0 else {
                    continuation.finish(
                        throwing: ActorLinkError.transportError("No connection"))
                    return
                }
                do {
                    while !Task.isCancelled {
                        let data = try self.readMessage(from: fd)
                        if data.isEmpty { continue }
                        let envelope = try JSONDecoder().decode(
                            Envelope.self, from: data)
                        continuation.yield(envelope)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Socket Setup

    private func createSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ActorLinkError.transportError(
                "Failed to create socket: \(errnoString())")
        }
        return fd
    }

    private func bindSocket(_ fd: Int32) throws {
        // Remove stale socket file from previous run
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = min(
            socketPath.utf8.count,
            MemoryLayout.size(ofValue: addr.sun_path) - 1)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                strncpy(dst, src, pathLen)
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(
                to: sockaddr.self, capacity: 1
            ) { addrPtr in
                Darwin.bind(
                    fd, addrPtr,
                    socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc >= 0 else {
            throw ActorLinkError.transportError(
                "Failed to bind socket at '\(socketPath)': \(errnoString())")
        }
    }

    private func connectSocket(_ fd: Int32) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = min(
            socketPath.utf8.count,
            MemoryLayout.size(ofValue: addr.sun_path) - 1)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                strncpy(dst, src, pathLen)
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(
                to: sockaddr.self, capacity: 1
            ) { addrPtr in
                Darwin.connect(
                    fd, addrPtr,
                    socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc >= 0 else {
            throw ActorLinkError.transportError(
                "Failed to connect to '\(socketPath)': \(errnoString())")
        }
    }

    // MARK: - Read / Write

    private func readMessage(from fd: Int32) throws -> Data {
        var rawLength: UInt32 = 0
        let n = withUnsafeMutableBytes(of: &rawLength) { ptr in
            read(fd, ptr.baseAddress, 4)
        }
        guard n == 4 else {
            throw ActorLinkError.transportError(
                "Failed to read message length (got \(n) bytes): \(errnoString())")
        }
        let messageLength = Int(UInt32(bigEndian: rawLength))
        guard messageLength > 0 else { return Data() }

        var buffer = Data(count: messageLength)
        var totalRead = 0
        while totalRead < messageLength {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                read(
                    fd,
                    ptr.baseAddress!.advanced(by: totalRead),
                    messageLength - totalRead)
            }
            guard bytesRead > 0 else {
                throw ActorLinkError.transportError(
                    "Connection closed during read: \(errnoString())")
            }
            totalRead += bytesRead
        }
        return buffer
    }

    private func writeLengthPrefixed(_ data: Data, to fd: Int32) throws {
        let length = UInt32(data.count).bigEndian
        var header = Data(count: 4)
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: length, as: UInt32.self)
        }
        let fullMessage = header + data

        var written = 0
        while written < fullMessage.count {
            let n = fullMessage.withUnsafeBytes { ptr in
                write(
                    fd, ptr.baseAddress!.advanced(by: written),
                    fullMessage.count - written)
            }
            guard n >= 0 else {
                throw ActorLinkError.transportError(
                    "Write failed: \(errnoString())")
            }
            written += n
        }
    }
}
