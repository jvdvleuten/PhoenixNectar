import Foundation

public enum PhoenixError: Error, Sendable {
  case malformedEndpoint(String)
  case encodingFailure(String)
  case decodingFailure(String)
  case notConnected
  case timeout
  case serverError(PhoenixMessage)
  case channelClosed(String)
}

extension PhoenixError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .malformedEndpoint(let value): return "Malformed endpoint: \(value)"
    case .encodingFailure(let value): return "Encoding failed: \(value)"
    case .decodingFailure(let value): return "Decoding failed: \(value)"
    case .notConnected: return "Socket is not connected"
    case .timeout: return "Request timed out"
    case .serverError(let message): return "Server error: \(message.payload)"
    case .channelClosed(let topic): return "Channel is closed: \(topic)"
    }
  }
}
