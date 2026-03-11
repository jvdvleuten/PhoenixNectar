import Testing
@testable import PhoenixNectar

@Suite(.timeLimit(.minutes(1)))
struct PhoenixValueTests {
  @Test
  func phoenixValueRoundTrip() throws {
    let frame = SocketFrame(joinRef: "1", ref: "2", topic: "room:lobby", event: "new_msg", payload: [
      "int": 42,
      "double": 3.14,
      "bool": true,
      "string": "hello",
      "array": [1, 2, "x"],
      "object": ["nested": "value"]
    ])

    let data = try Defaults.encodeFrame(frame)
    let decoded = try Defaults.decodeFrame(data)
    #expect(decoded == frame)
  }
}
