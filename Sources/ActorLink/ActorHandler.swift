/// Interface for objects that can handle envelopes dispatched to them.
///
/// Actors conforming to this protocol are registered with a `Dispatcher`
/// by name, and the dispatcher routes incoming envelopes to the appropriate handler.
public protocol ActorHandler: Sendable {
    /// Handle an incoming request envelope.
    /// - Parameter envelope: The request to handle.
    /// - Returns: A response to send back to the caller.
    func handle(_ envelope: Envelope) async throws -> RPCResponse
}
