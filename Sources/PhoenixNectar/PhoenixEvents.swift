import Foundation

/// A lightweight wrapper around a Phoenix topic string.
public struct Topic: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let rawValue: String

  /// Creates a topic from its raw Phoenix string form such as `"room:lobby"`.
  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  /// Creates a topic from a string literal.
  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }

  /// Convenience helper for the common `"room:<id>"` topic shape.
  public static func room(_ id: String) -> Topic {
    Topic("room:\(id)")
  }
}

/// Built-in Phoenix protocol events.
public enum PhoenixSystemEvent: String, Sendable, CaseIterable {
  case heartbeat = "heartbeat"
  case join = "phx_join"
  case leave = "phx_leave"
  case reply = "phx_reply"
  case error = "phx_error"
  case close = "phx_close"
}

/// A Phoenix event, either one of the system events or an application-defined event name.
public enum PhoenixEvent: Sendable, Hashable, RawRepresentable {
  case system(PhoenixSystemEvent)
  case named(String)

  /// Builds an event from a raw protocol string.
  public init(rawValue value: String) {
    if let system = PhoenixSystemEvent(rawValue: value) {
      self = .system(system)
    } else {
      self = .named(value)
    }
  }

  /// The raw Phoenix event name sent over the socket.
  public var rawValue: String {
    switch self {
    case .system(let value): return value.rawValue
    case .named(let value): return value
    }
  }
}

/// Status values returned by Phoenix replies.
public enum PushStatus: String, Sendable, CaseIterable {
  case ok
  case error
  case timeout
}

/// Connection lifecycle states emitted by ``Socket/connectionStateStream(bufferingPolicy:)``.
public enum ConnectionState: Sendable, Equatable {
  case idle
  case connecting
  case connected
  case reconnecting(attempt: Int, delay: Duration)
  case disconnected(code: Int, reason: String?)
  case failed(PhoenixError)
}

/// Normalized channel events emitted from the internal channel stream pipeline.
enum ChannelEvent: Sendable, Equatable {
  case reply(PhoenixReply)
  case system(PhoenixSystemEvent, PhoenixMessage)
  case named(String, PhoenixMessage)

  init(message: PhoenixMessage) {
    switch message.event {
    case .system(.reply):
      if let reply = try? message.replyEnvelope() {
        self = .reply(reply)
      } else {
        self = .system(.reply, message)
      }
    case .system(let event):
      self = .system(event, message)
    case .named(let event):
      self = .named(event, message)
    }
  }
}
