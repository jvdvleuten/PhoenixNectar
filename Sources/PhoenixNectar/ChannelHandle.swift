import Foundation

public struct ChannelHandle: Sendable {
  public let topic: String
  public let params: Payload
  private let client: PhoenixClient

  init(topic: String, params: Payload, client: PhoenixClient) {
    self.topic = topic
    self.params = params
    self.client = client
  }

  public func join(timeout: Duration = .seconds(Defaults.timeoutInterval)) async throws -> PhoenixMessage {
    try await client.join(topic: topic, params: params, timeout: timeout)
  }

  public func leave(timeout: Duration = .seconds(Defaults.timeoutInterval)) async throws -> PhoenixMessage {
    try await client.leave(topic: topic, timeout: timeout)
  }

  public func push(_ event: PhoenixEvent,
                   payload: Payload,
                   timeout: Duration = .seconds(Defaults.timeoutInterval)) async throws -> PhoenixMessage {
    try await client.push(topic: topic, event: event, payload: payload, timeout: timeout)
  }

  public func push<T: Encodable, Response: Decodable>(
    _ event: PhoenixEvent,
    payload: T,
    as responseType: Response.Type,
    timeout: Duration = .seconds(Defaults.timeoutInterval)
  ) async throws -> Response {
    let payloadValue = try PhoenixValue.fromEncodable(payload)
    guard case .object(let object) = payloadValue else {
      throw PhoenixError.encodingFailure("Encoded payload is not a JSON object")
    }

    let message = try await push(event, payload: object, timeout: timeout)
    return try message.responsePayload.decode(Response.self)
  }

  public func messages(
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncStream<PhoenixMessage> {
    await client.messages(topic: topic, bufferingPolicy: bufferingPolicy)
  }
}
