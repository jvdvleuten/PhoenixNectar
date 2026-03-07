// Copyright (c) 2021 David Stump <david@davidstump.net>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

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

    if try container.decodeNil() {
      self.joinRef = nil
    } else {
      self.joinRef = try container.decode(String.self)
    }

    if try container.decodeNil() {
      self.ref = nil
    } else {
      self.ref = try container.decode(String.self)
    }

    self.topic = try container.decode(String.self)
    self.event = try container.decode(String.self)
    self.payload = try container.decode(Payload.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    if let joinRef {
      try container.encode(joinRef)
    } else {
      try container.encodeNil()
    }

    if let ref {
      try container.encode(ref)
    } else {
      try container.encodeNil()
    }

    try container.encode(topic)
    try container.encode(event)
    try container.encode(payload)
  }
}

/// Data that is received from the Server.
public struct Message: Sendable {
  
  /// Reference number. Empty if missing
  public let ref: String
  
  /// Join Reference number
  internal let joinRef: String?
  
  /// Message topic
  public let topic: String
  
  /// Message event
  public let event: String
  
  /// The raw payload from the Message, including a nested response from
  /// phx_reply events. It is recommended to use `payload` instead.
  internal let rawPayload: Payload
  
  /// Message payload
  public var payload: Payload {
    guard let response = rawPayload["response"]?.objectValue
    else { return rawPayload }
    return response
  }
  
  /// Convenience accessor. Equivalent to getting the status as such:
  /// ```swift
  /// message.payload["status"]
  /// ```
  public var status: String? {
    return rawPayload["status"]?.stringValue
  }

  public var pushStatus: PushStatus? {
    guard let status else { return nil }
    return PushStatus(rawValue: status)
  }

  init(ref: String = "",
       topic: String = "",
       event: String = "",
       payload: Payload = [:],
       joinRef: String? = nil) {
    self.ref = ref
    self.topic = topic
    self.event = event
    self.rawPayload = payload
    self.joinRef = joinRef
  }

  init(frame: SocketFrame) {
    self.ref = frame.ref ?? ""
    self.joinRef = frame.joinRef
    self.topic = frame.topic
    self.event = frame.event
    self.rawPayload = frame.payload
  }
}
