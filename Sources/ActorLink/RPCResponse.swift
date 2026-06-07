import Foundation

/// The result of a remote procedure call.
///
/// Contains success/failure status and either a JSON-encoded payload
/// or an error description.
public struct RPCResponse: Codable, Sendable {
    /// Correlates this response to the originating request.
    public let id: UUID
    /// Whether the call completed successfully.
    public let success: Bool
    /// JSON-encoded return value (nil on failure).
    public let payload: Data?
    /// Error message (nil on success).
    public let error: String?

    public init(
        id: UUID,
        success: Bool,
        payload: Data? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.success = success
        self.payload = payload
        self.error = error
    }
}
