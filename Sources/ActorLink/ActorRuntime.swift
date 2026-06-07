import Foundation

/// Core runtime managing the IPC lifecycle, request dispatch, and pending calls.
///
/// `ActorRuntime` bridges the transport layer with the dispatcher and proxy.
/// On the **server side**, it listens for incoming envelopes and dispatches them
/// to registered handlers. On the **client side**, it sends envelopes and
/// correlates responses to their originating calls.
public actor ActorRuntime {
    private let transport: any ActorTransport
    private let dispatcher: Dispatcher
    private var pendingCalls: [UUID: CheckedContinuation<RPCResponse, any Error>] = [:]
    private var earlyResponses: [UUID: RPCResponse] = [:]
    private var receiveTask: Task<Void, any Error>?

    /// Create a new runtime.
    /// - Parameters:
    ///   - transport: The transport to use for communication.
    ///   - dispatcher: Optional dispatcher for server-side message routing.
    public init(transport: any ActorTransport, dispatcher: Dispatcher = Dispatcher()) {
        self.transport = transport
        self.dispatcher = dispatcher
    }

    /// Start the runtime and begin accepting messages.
    public func start() async throws {
        try await transport.start(id: UUID().uuidString)
        startReceiveLoop()
    }

    /// Stop the runtime and release all resources.
    public func stop() async throws {
        receiveTask?.cancel()
        receiveTask = nil
        try await transport.stop()
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: CancellationError())
        }
        pendingCalls.removeAll()
        earlyResponses.removeAll()
    }

    /// Send a request and await the typed response.
    /// - Parameters:
    ///   - actor: The target actor name.
    ///   - method: The method name to invoke.
    ///   - parameters: The parameters to encode.
    /// - Returns: The decoded response value.
    public func call<Return: Decodable & Sendable>(
        actor: String,
        method: String,
        parameters: some Encodable & Sendable
    ) async throws -> Return {
        let id = UUID()
        let payload = try JSONEncoder().encode(parameters)
        let envelope = Envelope(
            id: id,
            actor: actor,
            method: method,
            payload: payload
        )

        try await transport.send(envelope)

        let response: RPCResponse = try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.storeContinuation(for: id, continuation: continuation)
            }
        }

        if response.success, let data = response.payload {
            return try JSONDecoder().decode(Return.self, from: data)
        }
        throw ActorLinkError.rpcFailed(response.error ?? "Unknown error")
    }

    /// Register a handler in the dispatcher.
    /// - Parameters:
    ///   - handler: The handler to register.
    ///   - name: The actor name to register it under.
    public func registerHandler(_ handler: any ActorHandler, for name: String) {
        Task { await dispatcher.register(handler, for: name) }
    }

    // MARK: - Private

    private func startReceiveLoop() {
        receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            for try await envelope in await self.transport.receive() {
                await self.handleIncoming(envelope)
            }
        }
    }

    private func handleIncoming(_ envelope: Envelope) {
        if let replyTo = envelope.replyTo {
            guard
                let response = try? JSONDecoder().decode(
                    RPCResponse.self, from: envelope.payload)
            else { return }
            if let continuation = pendingCalls.removeValue(forKey: replyTo) {
                continuation.resume(returning: response)
            } else {
                earlyResponses[replyTo] = response
            }
        } else {
            Task {
                let response = await dispatcher.dispatch(envelope)
                let responseData =
                    (try? JSONEncoder().encode(response)) ?? Data()
                let responseEnvelope = Envelope(
                    id: UUID(),
                    actor: envelope.actor,
                    method: envelope.method,
                    payload: responseData,
                    replyTo: envelope.id
                )
                try? await transport.send(responseEnvelope)
            }
        }
    }

    private func storeContinuation(
        for id: UUID,
        continuation: CheckedContinuation<RPCResponse, any Error>
    ) {
        if let response = earlyResponses.removeValue(forKey: id) {
            continuation.resume(returning: response)
        } else {
            pendingCalls[id] = continuation
        }
    }
}
