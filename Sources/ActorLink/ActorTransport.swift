/// Abstraction for the underlying IPC transport mechanism.
///
/// Conformances handle the actual byte-level communication between processes.
/// The `ActorRuntime` uses this protocol to send requests and receive responses
/// without knowing whether the transport is a Unix Domain Socket, XPC, or
/// any other mechanism.
///
/// Implementations must be `Sendable` and typically use `os_unfair_lock` or
/// actor-based internal synchronization.
public protocol ActorTransport: AnyObject, Sendable {
    /// Start the transport and begin accepting or establishing connections.
    /// - Parameter id: A unique identifier for this transport instance.
    func start(id: String) async throws

    /// Stop the transport and release all resources.
    func stop() async throws

    /// Send an envelope through the transport.
    /// - Parameter envelope: The message to send.
    func send(_ envelope: Envelope) async throws

    /// Receive a stream of incoming envelopes.
    /// - Returns: An async throwing stream yielding received envelopes.
    func receive() -> AsyncThrowingStream<Envelope, any Error>
}
