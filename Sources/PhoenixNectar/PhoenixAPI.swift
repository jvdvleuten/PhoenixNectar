import Foundation

/// Provides the Phoenix auth token used during socket connection.
public typealias AuthTokenProvider = @Sendable () -> String?

/// A reusable description of a channel topic plus join params.
struct ChannelDescriptor: Sendable {
  public let topic: Topic
  public let params: Payload

  /// Creates a descriptor from a topic and already-encoded params.
  init(topic: Topic, params: Payload = [:]) {
    self.topic = topic
    self.params = params
  }

  /// Creates a descriptor from an encodable params object.
  init<P: Encodable>(topic: Topic, params: P) throws {
    let encoded = try PhoenixValue.fromEncodable(params)
    guard case .object(let object) = encoded else {
      throw PhoenixError.encodingFailure("Encoded channel params are not a JSON object")
    }

    self.topic = topic
    self.params = object
  }
}

/// Timeout and retry settings for one logical request.
public struct RequestPolicy: Sendable {
  public let timeout: Duration
  public let retries: Int
  public let retryBackoff: @Sendable (Int) -> Duration

  /// Creates a request policy with a timeout and optional retries.
  public init(
    timeout: Duration = .seconds(10),
    retries: Int = 0,
    retryBackoff: @escaping @Sendable (Int) -> Duration = { _ in .zero }
  ) {
    self.timeout = timeout
    self.retries = retries
    self.retryBackoff = retryBackoff
  }

  /// Default timeout/retry behavior used by the client and handle convenience APIs.
  public static let `default` = RequestPolicy()
}

/// Heartbeat and reconnect settings for the underlying socket connection.
public struct ConnectionPolicy: Sendable {
  public let heartbeatInterval: Duration
  public let reconnectBackoff: @Sendable (Int) -> Duration
  /// When `true`, the client reconnects after a server-initiated close with code 1000.
  ///
  /// Phoenix servers send a clean 1000 close during deployments. With this enabled
  /// (the default) the client automatically reconnects and rejoins its channels,
  /// providing seamless continuity across server restarts.
  ///
  /// Client-initiated ``Socket/disconnect(code:reason:)`` calls always remain terminal
  /// regardless of this setting.
  public let reconnectOnCleanClose: Bool

  /// Creates a connection policy with heartbeat timing and reconnect backoff.
  public init(
    heartbeatInterval: Duration = .seconds(30),
    reconnectBackoff: @escaping @Sendable (Int) -> Duration = { attempt in
      let schedule: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5]
      let index = min(max(attempt - 1, 0), schedule.count - 1)
      return .seconds(schedule[index])
    },
    reconnectOnCleanClose: Bool = true
  ) {
    self.heartbeatInterval = heartbeatInterval
    self.reconnectBackoff = reconnectBackoff
    self.reconnectOnCleanClose = reconnectOnCleanClose
  }

  /// Default heartbeat/reconnect behavior.
  public static let `default` = ConnectionPolicy()
}

/// Policy used when offline buffering reaches the configured limit.
public enum BufferOverflowPolicy: Sendable {
  case dropOldest
  case dropNewest
}

/// A typed push event that binds a request type to its expected decoded response type.
public struct Push<Request: Encodable & Sendable, Response: Decodable & Sendable>: Sendable, Hashable {
  public let event: PhoenixEvent

  /// Creates a typed push event from a Phoenix event.
  public init(_ event: PhoenixEvent) {
    self.event = event
  }

  /// Creates a typed push event from a raw event name.
  public init(_ eventName: String) {
    self.event = .named(eventName)
  }

  public static func named(_ eventName: String) -> Self {
    Self(eventName)
  }
}

/// A typed inbound event subscription descriptor.
public struct Event<EventPayload: Decodable & Sendable>: Sendable, Hashable {
  public let event: PhoenixEvent

  /// Creates a typed inbound event descriptor from a Phoenix event.
  public init(_ event: PhoenixEvent) {
    self.event = event
  }

  /// Creates a typed inbound event descriptor from a raw event name.
  public init(_ eventName: String) {
    self.event = .named(eventName)
  }

  public static func named(_ eventName: String) -> Self {
    Self(eventName)
  }
}

/// Metrics emitted by ``Socket`` for observability and testing.
public enum ClientMetricEvent: Sendable, Equatable {
  case connectionStateChanged(ConnectionState)
  case transport(TransportEvent)
  case frameBuffered(ref: String?, topic: Topic, event: PhoenixEvent)
  case frameSent(ref: String?, topic: Topic, event: PhoenixEvent)
  case frameDropped(ref: String?, topic: Topic, event: PhoenixEvent)
  case frameReceived(PhoenixMessage)
  case pushTimedOut(ref: String)
}

/// Receives metrics emitted by the client runtime.
public typealias ClientMetricsHook = @Sendable (ClientMetricEvent) -> Void
