import Foundation

/// Errors surfaced by PhoenixNectar for connection, protocol, and request failures.
public enum PhoenixError: Error, Sendable, Equatable {
  case malformedEndpoint(String)
  case encodingFailure(String)
  case decodingFailure(String)
  case protocolViolation(String)
  case notConnected
  case timeout
  case bufferOverflow(String)
  case serverError(PhoenixReply)
  case channelClosed(String)
}

extension PhoenixError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .malformedEndpoint(let value): return "Malformed endpoint: \(value)"
    case .encodingFailure(let value): return "Encoding failed: \(value)"
    case .decodingFailure(let value): return "Decoding failed: \(value)"
    case .protocolViolation(let value): return "Protocol violation: \(value)"
    case .notConnected: return "Socket is not connected"
    case .timeout: return "Request timed out"
    case .bufferOverflow(let value): return "Outbound buffer overflow: \(value)"
    case .serverError(let reply): return "Server error: \(reply.response)"
    case .channelClosed(let topic): return "Channel is closed: \(topic)"
    }
  }
}
