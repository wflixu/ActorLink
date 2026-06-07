/// Errors thrown by the ActorLink runtime.
public enum ActorLinkError: Error, Sendable {
    /// The remote call returned a failure response.
    case rpcFailed(String)
    /// The transport encountered an error.
    case transportError(String)
    /// The response could not be decoded.
    case decodingFailed(String)
}
