import Foundation

/// Phoenix protocol-level system event names used by channels and socket internals.
public enum PhoenixSystemEvent: String, Sendable, CaseIterable {
  case heartbeat = "heartbeat"
  case join = "phx_join"
  case leave = "phx_leave"
  case reply = "phx_reply"
  case error = "phx_error"
  case close = "phx_close"
}

/// Type-safe wrapper for event names, supporting both Phoenix system and custom app events.
public enum PhoenixEvent: Sendable, Hashable {
  case system(PhoenixSystemEvent)
  case custom(String)

  public var rawValue: String {
    switch self {
    case .system(let event):
      return event.rawValue
    case .custom(let event):
      return event
    }
  }
}

/// Status values returned in push replies.
public enum PushStatus: String, Sendable, CaseIterable {
  case ok
  case error
  case timeout
}
