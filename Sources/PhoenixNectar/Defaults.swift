import Foundation

enum Defaults {
  static let encodeFrame: @Sendable (SocketFrame) throws -> Data = { frame in
    do {
      return try JSONEncoder().encode(frame)
    } catch {
      throw PhoenixError.encodingFailure(error.localizedDescription)
    }
  }

  static let decodeFrame: @Sendable (Data) throws -> SocketFrame = { data in
    do {
      return try JSONDecoder().decode(SocketFrame.self, from: data)
    } catch {
      throw PhoenixError.decodingFailure(error.localizedDescription)
    }
  }
}
