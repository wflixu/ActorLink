import Foundation

/// The message unit for ActorLink IPC communication.
///
/// An `Envelope` wraps a method invocation for transport between processes.
/// It includes all metadata needed for the dispatcher to route and the runtime
/// to correlate requests with responses.
public struct Envelope: Codable, Sendable {
    /// Unique identifier for this message.
    public let id: UUID
    /// Target actor name for routing.
    public let actor: String
    /// Method name to invoke on the target actor.
    public let method: String
    /// JSON-encoded method parameters or response data.
    public let payload: Data
    /// If set, this envelope is a response to the request with this ID.
    public let replyTo: UUID?

    public init(
        id: UUID,
        actor: String,
        method: String,
        payload: Data,
        replyTo: UUID? = nil
    ) {
        self.id = id
        self.actor = actor
        self.method = method
        self.payload = payload
        self.replyTo = replyTo
    }
}
