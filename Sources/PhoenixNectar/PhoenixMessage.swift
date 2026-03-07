import Foundation

public struct SocketFrame: Sendable, Equatable, Codable {
  public let joinRef: String?
  public let ref: String?
  public let topic: String
  public let event: String
  public let payload: Payload

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

public struct PhoenixMessage: Sendable, Equatable {
  public let ref: String
  public let joinRef: String?
  public let topic: String
  public let event: String
  public let payload: Payload

  public init(frame: SocketFrame) {
    self.ref = frame.ref ?? ""
    self.joinRef = frame.joinRef
    self.topic = frame.topic
    self.event = frame.event
    self.payload = frame.payload
  }

  public var status: String? {
    payload["status"]?.stringValue
  }

  public var pushStatus: PushStatus? {
    guard let status else { return nil }
    return PushStatus(rawValue: status)
  }

  public var responsePayload: Payload {
    payload["response"]?.objectValue ?? payload
  }
}
