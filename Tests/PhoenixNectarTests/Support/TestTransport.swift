import Foundation
@testable import PhoenixNectar

final class TestTransport: PhoenixTransport {
    var readyState: PhoenixTransportReadyState = .closed

    private(set) var sentTexts: [String] = []
    private var continuation: AsyncStream<TransportEvent>.Continuation?

    func events(
        bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<TransportEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in }
        }
    }

    func connect(with headers: [String: String]) {
        readyState = .connecting
    }

    
    func disconnect(code: Int, reason: String?) {
        readyState = .closed
        continuation?.yield(.close(code, reason))
    }

    func send(data: Data) {
        sentTexts.append(String(decoding: data, as: UTF8.self))
    }

    
    func simulateOpen() {
        readyState = .open
        continuation?.yield(.open)
    }

    
    func simulateError(_ error: Error) {
        readyState = .closed
        continuation?.yield(.error(TransportFailure(message: error.localizedDescription)))
    }

    
    func simulateMessage(joinRef: String?, ref: String, topic: String, event: String, payload: Payload) {
        let frame = SocketFrame(joinRef: joinRef, ref: ref, topic: topic, event: event, payload: payload)
        let message: String
        do {
            let data = try Defaults.encodeFrame(frame)
            message = String(decoding: data, as: UTF8.self)
        } catch {
            return
        }
        continuation?.yield(.message(message))
    }

    func lastSentFrame() -> (joinRef: String?, ref: String, topic: String, event: String, payload: Payload)? {
        guard let text = sentTexts.last,
              let data = text.data(using: .utf8),
              let frame = try? Defaults.decodeFrame(data),
              let ref = frame.ref
        else {
            return nil
        }

        return (frame.joinRef, ref, frame.topic, frame.event, frame.payload)
    }
}

enum TestError: Error {
    case sample
}
