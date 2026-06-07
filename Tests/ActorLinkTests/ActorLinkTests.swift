import Testing
import Foundation
@testable import ActorLink

// MARK: - Helper

struct TestParams: Codable, Equatable {
    let value: String
}

struct TestResult: Codable, Equatable {
    let message: String
}

final class TestHandler: ActorHandler {
    let expectedActor: String

    init(expectedActor: String) { self.expectedActor = expectedActor }

    func handle(_ envelope: Envelope) async throws -> RPCResponse {
        let params = try JSONDecoder().decode(TestParams.self, from: envelope.payload)
        let result = TestResult(message: "hello \(params.value)")
        let data = try JSONEncoder().encode(result)
        return RPCResponse(id: envelope.id, success: true, payload: data)
    }
}

// MARK: - Envelope

@Test func envelopeEncoding() async throws {
    let payload = try JSONEncoder().encode(TestParams(value: "world"))
    let envelope = Envelope(
        id: UUID(),
        actor: "TestService",
        method: "ping",
        payload: payload
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(Envelope.self, from: data)

    #expect(decoded.actor == "TestService")
    #expect(decoded.method == "ping")
    #expect(decoded.replyTo == nil)
}

@Test func envelopeWithReplyTo() async throws {
    let replyTo = UUID()
    let envelope = Envelope(
        id: UUID(),
        actor: "TestService",
        method: "submit",
        payload: Data(),
        replyTo: replyTo
    )
    #expect(envelope.replyTo == replyTo)
}

// MARK: - RPCResponse

@Test func responseSuccess() async throws {
    let id = UUID()
    let data = try JSONEncoder().encode(TestResult(message: "ok"))
    let response = RPCResponse(id: id, success: true, payload: data)

    let decoded = try JSONDecoder().decode(RPCResponse.self, from: JSONEncoder().encode(response))
    #expect(decoded.id == id)
    #expect(decoded.success == true)
    #expect(decoded.error == nil)
}

@Test func responseFailure() async throws {
    let id = UUID()
    let response = RPCResponse(id: id, success: false, error: "oops")

    let decoded = try JSONDecoder().decode(RPCResponse.self, from: JSONEncoder().encode(response))
    #expect(decoded.success == false)
    #expect(decoded.error == "oops")
    #expect(decoded.payload == nil)
}

// MARK: - Dispatcher

@Test func dispatcherRoutesToHandler() async throws {
    let dispatcher = Dispatcher()
    let handler = TestHandler(expectedActor: "Greeter")
    await dispatcher.register(handler, for: "Greeter")

    let params = TestParams(value: "world")
    let payload = try JSONEncoder().encode(params)
    let envelope = Envelope(
        id: UUID(),
        actor: "Greeter",
        method: "greet",
        payload: payload
    )

    let response = await dispatcher.dispatch(envelope)
    #expect(response.success == true)

    let result = try JSONDecoder().decode(TestResult.self, from: response.payload!)
    #expect(result.message == "hello world")
}

@Test func dispatcherReturnsErrorForUnknownActor() async throws {
    let dispatcher = Dispatcher()
    let envelope = Envelope(
        id: UUID(),
        actor: "Unknown",
        method: "ping",
        payload: Data()
    )

    let response = await dispatcher.dispatch(envelope)
    #expect(response.success == false)
    #expect(response.error?.contains("Unknown actor") == true)
}

@Test func dispatcherUnregister() async throws {
    let dispatcher = Dispatcher()
    let handler = TestHandler(expectedActor: "Temp")
    await dispatcher.register(handler, for: "Temp")
    await dispatcher.unregister("Temp")

    let envelope = Envelope(id: UUID(), actor: "Temp", method: "ping", payload: Data())
    let response = await dispatcher.dispatch(envelope)
    #expect(response.success == false)
}

// MARK: - ActorRuntime

@Test func runtimeStartStop() async throws {
    let transport = MockTransport()
    let runtime = ActorRuntime(transport: transport)

    try await runtime.start()
    try await runtime.stop()
}

// MARK: - Mock Transport

final class MockTransport: ActorTransport {
    private let stream: AsyncThrowingStream<Envelope, any Error>
    private let streamContinuation: AsyncThrowingStream<Envelope, any Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<Envelope, any Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.streamContinuation = continuation
    }

    func start(id: String) async throws {}
    func stop() async throws {}
    func send(_ envelope: Envelope) async throws {}

    func receive() -> AsyncThrowingStream<Envelope, any Error> {
        stream
    }
}
