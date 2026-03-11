import Foundation
@testable import PhoenixNectar

typealias SentFrame = (joinRef: String?, ref: String, topic: String, event: String, payload: Payload)

actor TestTransport: PhoenixTransport {
  private var state: PhoenixTransportReadyState = .closed
  private var sentTexts: [String] = []
  private var sentBinary: [Data] = []
  private var continuation: AsyncStream<TransportEvent>.Continuation?
  private var lastConnectHeaders: [String: String] = [:]
  private var connectCalls: Int = 0

  // Event-driven notification streams for tests.
  private var frameContinuations: [UUID: AsyncStream<SentFrame>.Continuation] = [:]
  private var connectContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]

  func readyState() async -> PhoenixTransportReadyState {
    state
  }

  func events(bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy = .unbounded) async -> AsyncStream<TransportEvent> {
    let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: bufferingPolicy)
    self.continuation = continuation
    continuation.onTermination = { _ in
      Task { [weak self] in
        await self?.clearContinuation()
      }
    }
    return stream
  }

  private func clearContinuation() {
    continuation = nil
  }

  func connect(with headers: [String: String]) async {
    state = .connecting
    lastConnectHeaders = headers
    connectCalls += 1
    connectContinuations.values.forEach { $0.yield(connectCalls) }
  }

  func disconnect(code: Int, reason: String?) async {
    state = .closed
    continuation?.yield(.close(code, reason))
    continuation?.finish()
    continuation = nil
  }

  func sendText(data: Data) async {
    let text = String(decoding: data, as: UTF8.self)
    sentTexts.append(text)
    if let frame = Self.parseFrame(text) {
      frameContinuations.values.forEach { $0.yield(frame) }
    }
  }

  func sendBinary(data: Data) async {
    sentBinary.append(data)
  }

  func simulateOpen() {
    state = .open
    continuation?.yield(.open)
  }

  func simulateError(_ message: String) {
    continuation?.yield(.error(message))
    continuation?.finish()
    continuation = nil
  }

  func simulateClose(code: Int, reason: String?) {
    state = .closed
    continuation?.yield(.close(code, reason))
    continuation?.finish()
    continuation = nil
  }

  func simulateMessage(joinRef: String?, ref: String, topic: String, event: String, payload: Payload) {
    let frame = SocketFrame(joinRef: joinRef, ref: ref, topic: topic, event: event, payload: payload)
    guard let data = try? Defaults.encodeFrame(frame) else { return }
    continuation?.yield(.message(String(decoding: data, as: UTF8.self)))
  }

  func simulateText(_ text: String) {
    continuation?.yield(.message(text))
  }

  func simulateMessageData(_ data: Data) {
    continuation?.yield(.messageData(data))
  }

  func connectHeaders() -> [String: String] {
    lastConnectHeaders
  }

  func connectCallCount() -> Int {
    connectCalls
  }

  // MARK: - Event-driven frame stream (replaces polling)

  /// Returns an async stream that yields each sent frame as it happens.
  func sentFrameStream() -> AsyncStream<SentFrame> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<SentFrame>.makeStream(bufferingPolicy: .unbounded)
    frameContinuations[id] = continuation
    continuation.onTermination = { _ in
      Task { [weak self] in
        await self?.removeFrameContinuation(id: id)
      }
    }
    return stream
  }

  private func removeFrameContinuation(id: UUID) {
    frameContinuations[id] = nil
  }

  /// Returns an async stream that yields the connect call count each time connect() is called.
  func connectStream() -> AsyncStream<Int> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
    connectContinuations[id] = continuation
    continuation.onTermination = { _ in
      Task { [weak self] in
        await self?.removeConnectContinuation(id: id)
      }
    }
    return stream
  }

  private func removeConnectContinuation(id: UUID) {
    connectContinuations[id] = nil
  }

  // MARK: - Legacy accessors (still useful for snapshot assertions)

  func lastSentFrame() -> SentFrame? {
    guard let text = sentTexts.last else { return nil }
    return Self.parseFrame(text)
  }

  func sentFrames() -> [SentFrame] {
    sentTexts.compactMap { Self.parseFrame($0) }
  }

  func sentFrameCount() -> Int {
    sentTexts.count
  }

  func sentFrame(at index: Int) -> SentFrame? {
    guard index >= 0, index < sentTexts.count else { return nil }
    return Self.parseFrame(sentTexts[index])
  }

  func lastSentBinary() -> Data? {
    sentBinary.last
  }

  private static func parseFrame(_ text: String) -> SentFrame? {
    guard let data = text.data(using: .utf8),
          let frame = try? Defaults.decodeFrame(data),
          let ref = frame.ref
    else {
      return nil
    }
    return (frame.joinRef, ref, frame.topic, frame.event, frame.payload)
  }
}
