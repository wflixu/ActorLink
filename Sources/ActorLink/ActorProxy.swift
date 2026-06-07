/// Base class for type-safe client-side proxies.
///
/// Generators or manual subclasses provide typed methods that wrap calls
/// through the runtime.
///
/// ```swift
/// protocol MenuService {
///     func reloadMenus() async throws -> Bool
/// }
///
/// class MenuServiceProxy: ActorProxy, MenuService {
///     func reloadMenus() async throws -> Bool {
///         try await call(actor: "MenuService", method: "reloadMenus", parameters: [])
///     }
/// }
/// ```
open class ActorProxy: @unchecked Sendable {
    /// The runtime that manages transport and pending calls.
    public let runtime: ActorRuntime

    /// Create a proxy bound to the given runtime.
    /// - Parameter runtime: The runtime to use for communication.
    public init(runtime: ActorRuntime) {
        self.runtime = runtime
    }

    /// Perform a remote call through the runtime.
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
        try await runtime.call(
            actor: actor,
            method: method,
            parameters: parameters
        )
    }
}
