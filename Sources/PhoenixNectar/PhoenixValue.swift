import Foundation

public enum PhoenixValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([PhoenixValue])
  case object([String: PhoenixValue])
}

public typealias Payload = [String: PhoenixValue]
public typealias PayloadClosure = () -> Payload?

extension PhoenixValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension PhoenixValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: BooleanLiteralType) { self = .bool(value) }
}

extension PhoenixValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: IntegerLiteralType) { self = .int(value) }
}

extension PhoenixValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: FloatLiteralType) { self = .double(value) }
}

extension PhoenixValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: StringLiteralType) { self = .string(value) }
}

extension PhoenixValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: PhoenixValue...) { self = .array(elements) }
}

extension PhoenixValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, PhoenixValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

extension PhoenixValue {
  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    if case .int(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .double(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: PhoenixValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var arrayValue: [PhoenixValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  var queryValue: String {
    switch self {
    case .string(let value):
      return value
    default:
      let encoder = JSONEncoder()
      guard
        let data = try? encoder.encode(self),
        let string = String(data: data, encoding: .utf8)
      else {
        return ""
      }
      return string
    }
  }
}

extension Dictionary where Key == String, Value == PhoenixValue {
  public subscript(string key: String) -> String? {
    self[key]?.stringValue
  }

  public subscript(bool key: String) -> Bool? {
    self[key]?.boolValue
  }

  public subscript(int key: String) -> Int? {
    self[key]?.intValue
  }

  public subscript(double key: String) -> Double? {
    self[key]?.doubleValue
  }
}

extension PhoenixValue {
  public static func fromEncodable<T: Encodable>(_ value: T) throws -> PhoenixValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(PhoenixValue.self, from: data)
  }
}

extension Dictionary where Key == String, Value == PhoenixValue {
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(self)
    return try JSONDecoder().decode(type, from: data)
  }
}

extension PhoenixValue {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int.self) {
      self = .int(int)
    } else if let double = try? container.decode(Double.self) {
      self = .double(double)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([PhoenixValue].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: PhoenixValue].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported PhoenixValue payload"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let values):
      try container.encode(values)
    case .object(let values):
      try container.encode(values)
    }
  }
}
