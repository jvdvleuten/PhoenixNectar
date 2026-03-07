import Foundation
import Testing
@testable import PhoenixNectar

struct SerializationTests {
    @Test
    func socketFrameRoundTripPreservesPayloadShapeAndTypes() throws {
        let frame = SocketFrame(
            joinRef: "1",
            ref: "2",
            topic: "room:lobby",
            event: "new_msg",
            payload: [
                "int": 42,
                "double": 3.14,
                "string": "hello",
                "bool": true,
                "null": nil,
                "array": [1, 2.5, "x", true, nil],
                "object": ["nested": "value"]
            ]
        )

        let data = try Defaults.encodeFrame(frame)
        let decoded = try Defaults.decodeFrame(data)
        #expect(decoded == frame)
    }

    @Test
    func decodeFrameRejectsInvalidFramePayload() {
        let invalid = #"{"topic":"bad"}"#.data(using: .utf8)!

        do {
            _ = try Defaults.decodeFrame(invalid)
            Issue.record("Expected invalid frame error")
        } catch SerializationError.invalidFrame {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func phoenixValueCodablePreservesIntVsDouble() throws {
        let intData = "1".data(using: .utf8)!
        let doubleData = "1.5".data(using: .utf8)!

        let intValue = try JSONDecoder().decode(PhoenixValue.self, from: intData)
        let doubleValue = try JSONDecoder().decode(PhoenixValue.self, from: doubleData)

        #expect(intValue == .int(1))
        #expect(doubleValue == .double(1.5))
    }
}
