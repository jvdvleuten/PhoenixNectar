import Foundation

public enum Defaults {
  public static let timeoutInterval: TimeInterval = 10.0
  public static let heartbeatInterval: TimeInterval = 30.0
  public static let heartbeatTolerance: Duration = .milliseconds(10)

  public static let reconnectBackoff: @Sendable (Int) -> Duration = { attempt in
    let schedule: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5]
    let index = min(max(attempt - 1, 0), schedule.count - 1)
    return .seconds(schedule[index])
  }

  public static let rejoinBackoff: @Sendable (Int) -> Duration = { attempt in
    let schedule: [Double] = [0.5, 1, 2, 5, 10]
    let index = min(max(attempt - 1, 0), schedule.count - 1)
    return .seconds(schedule[index])
  }

  public static let vsn = "2.0.0"

  public static let encodeFrame: @Sendable (SocketFrame) throws -> Data = { frame in
    do {
      return try JSONEncoder().encode(frame)
    } catch {
      throw PhoenixError.encodingFailure(error.localizedDescription)
    }
  }

  public static let decodeFrame: @Sendable (Data) throws -> SocketFrame = { data in
    do {
      return try JSONDecoder().decode(SocketFrame.self, from: data)
    } catch {
      throw PhoenixError.decodingFailure(error.localizedDescription)
    }
  }
}
