import Foundation

public enum PhoenixSystemEvent: String, Sendable, CaseIterable {
  case heartbeat = "heartbeat"
  case join = "phx_join"
  case leave = "phx_leave"
  case reply = "phx_reply"
  case error = "phx_error"
  case close = "phx_close"
}

public enum PhoenixEvent: Sendable, Hashable {
  case system(PhoenixSystemEvent)
  case custom(String)

  public var rawValue: String {
    switch self {
    case .system(let value): return value.rawValue
    case .custom(let value): return value
    }
  }
}

public enum PushStatus: String, Sendable, CaseIterable {
  case ok
  case error
  case timeout
}

public enum ClientEvent: Sendable {
  case connected
  case disconnected(code: Int, reason: String?)
  case transportError(String)
  case message(PhoenixMessage)
}
