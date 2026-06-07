import Testing
import Foundation
@testable import ActorLink
@testable import ActorLinkSocket

// MARK: - LocalSocketTransport End-to-End

@Test func transportPingPong() async throws {
    let socketPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("al-test-\(UUID().uuidString).sock")
        .path

    let server = LocalSocketTransport(socketPath: socketPath, isServer: true)
    let client = LocalSocketTransport(socketPath: socketPath, isServer: false)

    try await server.start(id: "server")
    try await client.start(id: "client")

    // Start server receive stream
    let serverStream = server.receive()

    // Client sends a request
    let pingID = UUID()
    let ping = Envelope(
        id: pingID, actor: "Echo", method: "ping", payload: Data("\"hello\"".utf8))
    try await client.send(ping)

    // Server receives
    var iter = serverStream.makeAsyncIterator()
    let maybeReceived = try await iter.next()
    let received = try #require(maybeReceived)
    #expect(received.actor == "Echo")
    #expect(received.method == "ping")

    // Server sends a response
    let pongData = try JSONEncoder().encode(RPCResponse(
        id: pingID, success: true, payload: Data("\"world\"".utf8)))
    let pong = Envelope(
        id: UUID(), actor: "Echo", method: "ping",
        payload: pongData, replyTo: pingID)
    try await server.send(pong)

    // Client receives the response
    let clientStream = client.receive()
    var clientIter = clientStream.makeAsyncIterator()
    let maybeResponse = try await clientIter.next()
    let response = try #require(maybeResponse)
    #expect(response.replyTo == pingID)

    let decoded = try JSONDecoder().decode(
        RPCResponse.self, from: response.payload)
    #expect(decoded.success == true)

    // Cleanup
    try await server.stop()
    try await client.stop()
    try? FileManager.default.removeItem(atPath: socketPath)
}

@Test func transportSendReceiveMultipleMessages() async throws {
    let socketPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("al-test-\(UUID().uuidString).sock")
        .path

    let server = LocalSocketTransport(socketPath: socketPath, isServer: true)
    let client = LocalSocketTransport(socketPath: socketPath, isServer: false)

    try await server.start(id: "server")
    try await client.start(id: "client")

    let serverStream = server.receive()
    var serverIter = serverStream.makeAsyncIterator()

    // Send 3 messages from client
    for i in 0..<3 {
        let env = Envelope(
            id: UUID(), actor: "Test", method: "msg\(i)",
            payload: Data("\"msg\(i)\"".utf8))
        try await client.send(env)
    }

    // Verify all received
    for i in 0..<3 {
        let maybeReceived = try await serverIter.next()
        let received = try #require(maybeReceived)
        #expect(received.method == "msg\(i)")
    }

    try await server.stop()
    try await client.stop()
    try? FileManager.default.removeItem(atPath: socketPath)
}

// MARK: - ActorRuntime Integration

@Test func runtimeFullRoundTrip() async throws {
    let socketPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("al-test-\(UUID().uuidString).sock")
        .path

    let serverTransport = LocalSocketTransport(socketPath: socketPath, isServer: true)
    let clientTransport = LocalSocketTransport(socketPath: socketPath, isServer: false)

    let dispatcher = Dispatcher()
    let handler = EchoHandler()
    await dispatcher.register(handler, for: "Echo")

    let serverRuntime = ActorRuntime(transport: serverTransport, dispatcher: dispatcher)
    let clientRuntime = ActorRuntime(transport: clientTransport)

    try await serverRuntime.start()
    try await clientRuntime.start()

    let result: String = try await clientRuntime.call(
        actor: "Echo", method: "echo", parameters: ["hello"])

    #expect(result == "received: hello")

    try await clientRuntime.stop()
    try await serverRuntime.stop()
    try? FileManager.default.removeItem(atPath: socketPath)
}

// MARK: - Helpers

private struct EchoHandler: ActorHandler {
    func handle(_ envelope: Envelope) async throws -> RPCResponse {
        let input = try JSONDecoder().decode([String].self, from: envelope.payload)
        let result = "received: \(input.first ?? "")"
        let data = try JSONEncoder().encode(result)
        return RPCResponse(id: envelope.id, success: true, payload: data)
    }
}
