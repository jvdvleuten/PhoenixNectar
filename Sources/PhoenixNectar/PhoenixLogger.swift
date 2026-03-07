import Foundation

public enum LogLevel: String, Sendable {
  case debug
  case info
  case warning
  case error
}

public struct LogEvent: Sendable {
  public let level: LogLevel
  public let category: String
  public let message: String
  public let metadata: [String: String]

  public init(level: LogLevel, category: String, message: String, metadata: [String: String] = [:]) {
    self.level = level
    self.category = category
    self.message = message
    self.metadata = metadata
  }
}

public protocol PhoenixLogger: Sendable {
  func log(_ event: LogEvent)
}
