import Foundation
import ActorLink
import OSLog

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

// MARK: - Transport State

/// Thread-safe container for transport mutable state.
private struct TransportState: Sendable {
    var serverFD: Int32 = -1
    var connectionFD: Int32 = -1
    var isRunning = false

    mutating func cleanup() {
        if connectionFD >= 0 {
            close(connectionFD)
            connectionFD = -1
        }
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        isRunning = false
    }
}

// MARK: - LocalSocketTransport

/// A transport that communicates over a Unix Domain Socket.
///
/// Uses length-prefixed framing:
/// - 4 bytes: message length as big-endian `UInt32`
/// - N bytes: JSON-encoded `Envelope`
///
/// On the server side it listens and accepts a single connection.
/// On the client side it connects to an existing socket.
public final class LocalSocketTransport: @unchecked Sendable, ActorTransport {
    private let state = OSAllocatedUnfairLock(initialState: TransportState())
    private let socketPath: String
    private let isServer: Bool
    private let logger = Logger(subsystem: "com.actorlink", category: "socket")

    /// Create a transport using a Unix Domain Socket.
    /// - Parameters:
    ///   - socketPath: Path for the socket file.
    ///   - isServer: `true` to listen/accept (server), `false` to connect (client).
    public init(socketPath: String, isServer: Bool) {
        self.socketPath = socketPath
        self.isServer = isServer
    }

    deinit {
        state.withLock { $0.cleanup() }
    }

    // MARK: - ActorTransport

    public func start(id: String) async throws {
        try state.withLock { state in
            guard !state.isRunning else { return }
            try setupSocket(state: &state)
            state.isRunning = true
        }
    }

    public func stop() async throws {
        state.withLock { $0.cleanup() }
    }

    public func send(_ envelope: Envelope) async throws {
        let data = try JSONEncoder().encode(envelope)
        try state.withLock { state in
            let fd = state.connectionFD >= 0 ? state.connectionFD : state.serverFD
            guard fd >= 0 else {
                throw ActorLinkError.transportError("No connection available")
            }
            try writeLengthPrefixed(data, to: fd)
        }
    }

    public func receive() -> AsyncThrowingStream<Envelope, any Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else { return }
                let readFD = self.state.withLock { state in
                    state.connectionFD >= 0 ? state.connectionFD : state.serverFD
                }
                guard readFD >= 0 else {
                    continuation.finish(throwing: ActorLinkError.transportError("No connection"))
                    return
                }
                do {
                    while !Task.isCancelled {
                        let data = try self.readMessage(from: readFD)
                        if data.isEmpty { continue }
                        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                        continuation.yield(envelope)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Socket

    private func setupSocket(state: inout TransportState) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ActorLinkError.transportError("Failed to create socket")
        }
        state.serverFD = fd

        // Remove existing socket file if present
        if isServer {
            unlink(socketPath)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = min(socketPath.utf8.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                strncpy(dst, src, pathLength)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                if isServer {
                    Darwin.bind(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                } else {
                    Darwin.connect(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }

        if result < 0 {
            throw ActorLinkError.transportError("Failed to bind/connect socket")
        }

        if isServer {
            listen(fd, 1)
            logger.debug("Listening on \(self.socketPath)")

            // Accept a single connection (blocks until connected)
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                throw ActorLinkError.transportError("Failed to accept connection")
            }
            state.connectionFD = clientFD
            logger.debug("Client connected")
        } else {
            state.connectionFD = fd
            logger.debug("Connected to \(self.socketPath)")
        }
    }

    /// Read one length-prefixed message from a file descriptor.
    private func readMessage(from fd: Int32) throws -> Data {
        var rawLength: UInt32 = 0
        let lengthBytes = withUnsafeMutableBytes(of: &rawLength) { ptr in
            read(fd, ptr.baseAddress, 4)
        }
        guard lengthBytes == 4 else {
            throw ActorLinkError.transportError("Failed to read message length")
        }
        let messageLength = Int(UInt32(bigEndian: rawLength))
        guard messageLength > 0 else { return Data() }

        var buffer = [UInt8](repeating: 0, count: messageLength)
        var totalRead = 0
        while totalRead < messageLength {
            let bytesRead = read(fd, &buffer[totalRead], messageLength - totalRead)
            guard bytesRead > 0 else {
                throw ActorLinkError.transportError("Connection closed during read")
            }
            totalRead += bytesRead
        }
        return Data(buffer)
    }

    /// Write data as a length-prefixed message.
    private func writeLengthPrefixed(_ data: Data, to fd: Int32) throws {
        let rawLength = UInt32(data.count).bigEndian
        var header = Data(count: 4)
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: rawLength, as: UInt32.self)
        }
        var written = 0
        let totalBytes = data.count
        let fullMessage = header + data
        while written < totalBytes + 4 {
            let bytes = write(fd, (fullMessage as NSData).bytes + written, fullMessage.count - written)
            guard bytes >= 0 else {
                throw ActorLinkError.transportError("Write failed")
            }
            written += bytes
        }
    }
}
