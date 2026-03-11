import Foundation

enum PhoenixReplyBody: Sendable, Equatable {
  case object(Payload)
  case binary(Data)
}

/// Raw Phoenix frame representation used for JSON encode/decode.
struct SocketFrame: Sendable, Equatable, Codable {
  public let joinRef: String?
  public let ref: String?
  public let topic: String
  public let event: String
  public let payload: Payload

  /// Creates a Phoenix frame from its protocol fields.
  public init(joinRef: String?, ref: String?, topic: String, event: String, payload: Payload) {
    self.joinRef = joinRef
    self.ref = ref
    self.topic = topic
    self.event = event
    self.payload = payload
  }

  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    self.joinRef = try container.decodeIfPresent(String.self)
    self.ref = try container.decodeIfPresent(String.self)
    self.topic = try container.decode(String.self)
    self.event = try container.decode(String.self)
    self.payload = try container.decode(Payload.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    if let joinRef { try container.encode(joinRef) } else { try container.encodeNil() }
    if let ref { try container.encode(ref) } else { try container.encodeNil() }
    try container.encode(topic)
    try container.encode(event)
    try container.encode(payload)
  }
}

/// A decoded Phoenix text message with normalized topic/event types.
public struct PhoenixMessage: Sendable, Equatable {
  public let ref: String?
  public let joinRef: String?
  public let topic: Topic
  public let event: PhoenixEvent
  let payload: Payload

  /// Creates a message from a decoded socket frame.
  init(frame: SocketFrame) {
    self.ref = frame.ref
    self.joinRef = frame.joinRef
    self.topic = Topic(frame.topic)
    if let system = PhoenixSystemEvent(rawValue: frame.event) {
      self.event = .system(system)
    } else {
      self.event = .named(frame.event)
    }
    self.payload = frame.payload
  }

  /// The reply status string if this message is a Phoenix reply.
  public var status: String? {
    payload["status"]?.stringValue
  }

  /// The typed push status if this message is a Phoenix reply.
  public var pushStatus: PushStatus? {
    guard let status else { return nil }
    return PushStatus(rawValue: status)
  }

  /// The reply response payload for reply messages, or the full payload for non-reply events.
  var responsePayload: Payload {
    payload["response"]?.objectValue ?? payload
  }

  /// Decodes the message payload into a strongly typed value.
  public func decodePayload<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
    try payload.decode(type)
  }

  /// Decodes this message as a protocol-level reply envelope.
  public func replyEnvelope() throws -> PhoenixReply {
    try PhoenixReply(message: self)
  }
}

/// A Phoenix binary message emitted from the internal channel stream pipeline.
struct PhoenixBinaryMessage: Sendable, Equatable {
  public let ref: String?
  public let joinRef: String?
  public let topic: Topic
  public let event: PhoenixEvent
  public let payload: Data

  /// Creates a Phoenix binary message.
  public init(ref: String?, joinRef: String?, topic: Topic, event: PhoenixEvent, payload: Data) {
    self.ref = ref
    self.joinRef = joinRef
    self.topic = topic
    self.event = event
    self.payload = payload
  }
}

/// A decoded `phx_reply` envelope containing status and response payload.
public struct PhoenixReply: Sendable, Equatable {
  public let ref: String
  public let joinRef: String?
  public let topic: Topic
  public let status: PushStatus
  private let body: PhoenixReplyBody

  /// Creates a reply envelope from its protocol fields.
  init(ref: String, joinRef: String?, topic: Topic, status: PushStatus, response: Payload) {
    self.ref = ref
    self.joinRef = joinRef
    self.topic = topic
    self.status = status
    self.body = .object(response)
  }

  /// Creates a reply envelope from its protocol fields with a raw binary response body.
  init(ref: String, joinRef: String?, topic: Topic, status: PushStatus, binaryResponse: Data) {
    self.ref = ref
    self.joinRef = joinRef
    self.topic = topic
    self.status = status
    self.body = .binary(binaryResponse)
  }

  /// Creates a reply from an inbound Phoenix message.
  public init(message: PhoenixMessage) throws {
    guard message.event == .system(.reply) else {
      throw PhoenixError.protocolViolation("Message is not a reply event")
    }
    guard let ref = message.ref, !ref.isEmpty else {
      throw PhoenixError.protocolViolation("Reply is missing ref")
    }
    guard let rawStatus = message.status, let status = PushStatus(rawValue: rawStatus) else {
      throw PhoenixError.protocolViolation("Reply is missing valid status")
    }

    self.ref = ref
    self.joinRef = message.joinRef
    self.topic = message.topic
    self.status = status
    self.body = .object(message.responsePayload)
  }
}

public extension PhoenixReply {
  /// The raw binary response body for binary replies, if present.
  var binaryResponse: Data? {
    guard case .binary(let data) = body else { return nil }
    return data
  }

  /// Decodes the reply payload.
  func decode<Response: Decodable & Sendable>(_ type: Response.Type) throws -> Response {
    let decoded: Response

    switch body {
    case .object(let response):
      decoded = try response.decode(Response.self)
    case .binary(let data):
      if let raw = data as? Response {
        decoded = raw
      } else {
        do {
          decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
          throw PhoenixError.decodingFailure(error.localizedDescription)
        }
      }
    }

    return decoded
  }
}

extension PhoenixReply {
  var response: Payload {
    guard case .object(let payload) = body else { return [:] }
    return payload
  }
}
