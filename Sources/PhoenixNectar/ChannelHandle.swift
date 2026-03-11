import Foundation
#if canImport(os)
import os
#endif

private final class StreamForwarder: Sendable {
  #if canImport(os)
  private let state = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

  func start(_ operation: @escaping @Sendable () async -> Void) {
    let task = Task {
      await operation()
      self.state.withLock { $0 = nil }
    }
    state.withLock { $0 = task }
  }

  func cancel() {
    state.withLock { task in
      task?.cancel()
      task = nil
    }
  }

  deinit {
    state.withLock { $0?.cancel() }
  }
  #else
  private nonisolated(unsafe) let lock = NSLock()
  private nonisolated(unsafe) var _task: Task<Void, Never>?

  func start(_ operation: @escaping @Sendable () async -> Void) {
    let newTask = Task { [self] in
      await operation()
      _ = self
    }
    lock.lock()
    _task = newTask
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    let current = _task
    _task = nil
    lock.unlock()
    current?.cancel()
  }

  deinit {
    _task?.cancel()
  }
  #endif
}

/// Value-type facade for performing operations against one Phoenix topic.
public struct Channel: Sendable {
  public let topic: Topic
  let params: Payload
  private let client: Socket

  init(topic: Topic, params: Payload, client: Socket) {
    self.topic = topic
    self.params = params
    self.client = client
  }

  /// Joins the channel using the handle's stored params.
  public func join(policy: RequestPolicy = .default) async throws -> PhoenixReply {
    try await client.join(topic: topic, params: params, policy: policy)
  }

  /// Leaves the channel.
  public func leave(policy: RequestPolicy = .default) async throws -> PhoenixReply {
    try await client.leave(topic: topic, policy: policy)
  }

  func push(
    _ eventName: String,
    payload: Payload,
    policy: RequestPolicy = .default
  ) async throws -> PhoenixReply {
    try await client.push(topic: topic, event: .named(eventName), payload: payload, policy: policy)
  }

  /// Sends a binary push using a raw event name.
  public func pushBinary(
    _ eventName: String,
    data: Data,
    policy: RequestPolicy = .default
  ) async throws -> PhoenixReply {
    try await client.pushBinary(topic: topic, event: .named(eventName), data: data, policy: policy)
  }

  /// Sends a typed push and decodes the reply payload.
  public func push<Request: Encodable & Sendable, Response: Decodable & Sendable>(
    _ event: Push<Request, Response>,
    payload: Request,
    policy: RequestPolicy = .default
  ) async throws -> Response {
    let payloadValue = try PhoenixValue.fromEncodable(payload)
    guard case .object(let object) = payloadValue else {
      throw PhoenixError.encodingFailure("Encoded payload is not a JSON object")
    }
    let reply = try await client.push(topic: topic, event: event.event, payload: object, policy: policy)
    return try reply.decode(Response.self)
  }

  /// Sends an encodable payload to a raw event name and returns the raw reply.
  public func push<T: Encodable>(
    _ eventName: String,
    payload: T,
    policy: RequestPolicy = .default
  ) async throws -> PhoenixReply {
    let payloadValue = try PhoenixValue.fromEncodable(payload)
    guard case .object(let object) = payloadValue else {
      throw PhoenixError.encodingFailure("Encoded payload is not a JSON object")
    }
    return try await push(eventName, payload: object, policy: policy)
  }

  func messages<EventPayload: Decodable & Sendable>(
    of type: EventPayload.Type,
    for event: PhoenixEvent,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncThrowingStream<EventPayload, Error> {
    let (source, cancelSource) = await client.makeMessagesStream(topic: topic, bufferingPolicy: bufferingPolicy)
    let forwarder = StreamForwarder()

    return AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak forwarder] _ in
        forwarder?.cancel()
        cancelSource()
      }

      forwarder.start {
        do {
          for await message in source {
            guard !Task.isCancelled else { break }
            guard message.event == event else { continue }

            let payload: Payload
            if event == .system(.reply) {
              payload = try message.replyEnvelope().response
            } else {
              payload = message.payload
            }

            continuation.yield(try payload.decode(EventPayload.self))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        cancelSource()
      }
    }
  }

  func subscribe<EventPayload: Decodable & Sendable>(
    _ type: EventPayload.Type,
    on event: PhoenixEvent,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncThrowingStream<EventPayload, Error> {
    await messages(of: type, for: event, bufferingPolicy: bufferingPolicy)
  }

  /// Returns a typed async stream for a specific inbound event.
  public func subscribe<EventPayload: Decodable & Sendable>(
    to event: Event<EventPayload>,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncThrowingStream<EventPayload, Error> {
    await subscribe(EventPayload.self, on: event.event, bufferingPolicy: bufferingPolicy)
  }

  /// Returns a stream of binary payloads for one inbound binary event name.
  public func subscribeBinary(
    to eventName: String,
    bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncStream<Data> {
    let source = await client.binaryMessages(
      topic: topic,
      bufferingPolicy: Self.binaryBufferingPolicy(from: bufferingPolicy)
    )
    let forwarder = StreamForwarder()

    return AsyncStream<Data>(bufferingPolicy: bufferingPolicy) { continuation in
      continuation.onTermination = { [weak forwarder] _ in
        forwarder?.cancel()
      }

      forwarder.start {
        for await message in source {
          guard !Task.isCancelled else { break }
          guard message.event == .named(eventName) else { continue }
          continuation.yield(message.payload)
        }
        continuation.finish()
      }
    }
  }

  private static func binaryBufferingPolicy(
    from policy: AsyncStream<Data>.Continuation.BufferingPolicy
  ) -> AsyncStream<PhoenixBinaryMessage>.Continuation.BufferingPolicy {
    switch policy {
    case .unbounded:
      return .unbounded
    case .bufferingNewest(let limit):
      return .bufferingNewest(limit)
    case .bufferingOldest(let limit):
      return .bufferingOldest(limit)
    @unknown default:
      return .unbounded
    }
  }

}
