import Foundation
import PhoenixNectar

func uploadChunk(fileURL: URL, over channel: Channel) async throws {
  let data = try Data(contentsOf: fileURL)
  let reply = try await channel.pushBinary("upload:chunk", data: data)
  print("upload status:", reply.status)
}
