/// Server-side router that dispatches incoming envelopes to registered handlers.
///
/// The `Dispatcher` maintains a registry of named `ActorHandler` instances.
/// When an envelope arrives, the dispatcher looks up the handler by the
/// ``Envelope/actor`` field and forwards the envelope for processing.
///
/// ```swift
/// let dispatcher = Dispatcher()
/// await dispatcher.register(myService, for: "MenuService")
/// let response = await dispatcher.dispatch(envelope)
/// ```
public actor Dispatcher {
    private var handlers: [String: any ActorHandler] = [:]

    public init() {}

    /// Register a handler for a given actor name.
    /// - Parameters:
    ///   - handler: The handler to register.
    ///   - actorName: The name to route messages to this handler.
    public func register(_ handler: any ActorHandler, for actorName: String) {
        handlers[actorName] = handler
    }

    /// Remove a registered handler.
    /// - Parameter actorName: The name of the handler to remove.
    public func unregister(_ actorName: String) {
        handlers.removeValue(forKey: actorName)
    }

    /// Dispatch an envelope to the appropriate handler.
    /// - Parameter envelope: The incoming request.
    /// - Returns: The response from the handler, or an error response if
    ///   no handler is registered for the target actor.
    public func dispatch(_ envelope: Envelope) async -> RPCResponse {
        guard let handler = handlers[envelope.actor] else {
            return RPCResponse(
                id: envelope.id,
                success: false,
                error: "Unknown actor: \(envelope.actor)"
            )
        }
        do {
            return try await handler.handle(envelope)
        } catch {
            return RPCResponse(
                id: envelope.id,
                success: false,
                error: error.localizedDescription
            )
        }
    }
}
