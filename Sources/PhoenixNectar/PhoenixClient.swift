import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor PhoenixClient {
  public let endpoint: String
  public let vsn: String
  public var headers: [String: String] = [:]
  public var heartbeatInterval: Duration = .seconds(Defaults.heartbeatInterval)
  public var reconnectAfter: @Sendable (Int) -> Duration = Defaults.reconnectBackoff
  public var logger: (any PhoenixLogger)?

  private let paramsClosure: PayloadClosure?
  private let transportFactory: @Sendable (URL) -> any PhoenixTransport
  private var endpointURL: URL

  private var transport: (any PhoenixTransport)?
  private var transportTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?

  private var nextRefCounter: UInt64 = 0
  private var pendingHeartbeatRef: String?
  private var reconnectAttempts: Int = 0

  private var sendBuffer: [SocketFrame] = []

  private var globalContinuations: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]
  private var topicContinuations: [String: [UUID: AsyncStream<PhoenixMessage>.Continuation]] = [:]

  private var replyWaiters: [String: CheckedContinuation<PhoenixMessage, Error>] = [:]
  private var channelJoinRefs: [String: String] = [:]

  public init(
    endpoint: String,
    paramsClosure: PayloadClosure? = nil,
    vsn: String = Defaults.vsn,
    transportFactory: @escaping @Sendable (URL) -> any PhoenixTransport = { URLSessionTransport(url: $0) }
  ) throws {
    self.endpoint = endpoint
    self.paramsClosure = paramsClosure
    self.vsn = vsn
    self.transportFactory = transportFactory
    self.endpointURL = try Self.buildEndpointURL(endpoint: endpoint, paramsClosure: paramsClosure, vsn: vsn)
  }

  public func connect() async throws {
    guard transport?.readyState != .open && transport?.readyState != .connecting else { return }
    endpointURL = try Self.buildEndpointURL(endpoint: endpoint, paramsClosure: paramsClosure, vsn: vsn)
    reconnectAttempts = 0

    let transport = transportFactory(endpointURL)
    self.transport = transport
    consumeTransportEvents(transport)
    transport.connect(with: headers)
  }

  public func disconnect(code: Int = 1000, reason: String? = nil) {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    transportTask?.cancel()
    transportTask = nil
    transport?.disconnect(code: code, reason: reason)
    transport = nil
    emit(.disconnected(code: code, reason: reason))
  }

  public func channel(_ topic: String, params: Payload = [:]) -> ChannelHandle {
    ChannelHandle(topic: topic, params: params, client: self)
  }

  public func events(
    bufferingPolicy: AsyncStream<ClientEvent>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<ClientEvent> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      let id = UUID()
      Task { await self.registerGlobalContinuation(continuation, id: id) }
      continuation.onTermination = { _ in
        Task { await self.unregisterGlobalContinuation(id: id) }
      }
    }
  }

  public func messages(
    topic: String,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<PhoenixMessage> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      let id = UUID()
      Task { await self.registerTopicContinuation(continuation, id: id, topic: topic) }
      continuation.onTermination = { _ in
        Task { await self.unregisterTopicContinuation(id: id, topic: topic) }
      }
    }
  }

  // MARK: Channel Operations
  func join(topic: String, params: Payload, timeout: Duration) async throws -> PhoenixMessage {
    let joinRef = makeRef()
    channelJoinRefs[topic] = joinRef
    return try await push(topic: topic, event: .system(.join), payload: params, joinRef: joinRef, timeout: timeout)
  }

  func leave(topic: String, timeout: Duration) async throws -> PhoenixMessage {
    defer { channelJoinRefs.removeValue(forKey: topic) }
    let joinRef = channelJoinRefs[topic]
    return try await push(topic: topic, event: .system(.leave), payload: [:], joinRef: joinRef, timeout: timeout)
  }

  func push(topic: String,
            event: PhoenixEvent,
            payload: Payload,
            timeout: Duration) async throws -> PhoenixMessage {
    try await push(topic: topic, event: event, payload: payload, joinRef: channelJoinRefs[topic], timeout: timeout)
  }

  private func push(topic: String,
                    event: PhoenixEvent,
                    payload: Payload,
                    joinRef: String?,
                    timeout: Duration) async throws -> PhoenixMessage {
    let ref = makeRef()
    let frame = SocketFrame(joinRef: joinRef, ref: ref, topic: topic, event: event.rawValue, payload: payload)
    try sendOrBuffer(frame)

    return try await withThrowingTaskGroup(of: PhoenixMessage.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          Task {
            await self.registerReplyWaiter(ref: ref, continuation: continuation)
          }
        }
      }

      group.addTask {
        try await Task.sleep(for: timeout)
        throw PhoenixError.timeout
      }

      guard let result = try await group.next() else {
        throw PhoenixError.timeout
      }
      group.cancelAll()
      return result
    }
  }

  // MARK: Transport
  private func consumeTransportEvents(_ transport: any PhoenixTransport) {
    transportTask?.cancel()
    transportTask = Task { [weak transport] in
      guard let transport else { return }
      let stream = transport.events(bufferingPolicy: .unbounded)
      for await event in stream {
        await self.handleTransportEvent(event)
      }
    }
  }

  private func handleTransportEvent(_ event: TransportEvent) async {
    switch event {
    case .open:
      emit(.connected)
      reconnectAttempts = 0
      flushSendBuffer()
      startHeartbeatLoop()
    case .message(let raw):
      guard let data = raw.data(using: .utf8) else { return }
      do {
        let frame = try Defaults.decodeFrame(data)
        let message = PhoenixMessage(frame: frame)

        if let pending = pendingHeartbeatRef, pending == message.ref {
          pendingHeartbeatRef = nil
        }

        if let waiter = replyWaiters.removeValue(forKey: message.ref) {
          waiter.resume(returning: message)
        }

        emit(.message(message))
        emitTopic(message)
      } catch {
        emit(.transportError(error.localizedDescription))
      }
    case .close(let code, let reason):
      heartbeatTask?.cancel()
      heartbeatTask = nil
      emit(.disconnected(code: code, reason: reason))
      await scheduleReconnectIfNeeded(code: code)
    case .error(let error):
      emit(.transportError(error))
    }
  }

  private func scheduleReconnectIfNeeded(code: Int) async {
    guard code == 999 else { return }
    reconnectAttempts += 1
    let delay = reconnectAfter(reconnectAttempts)
    do {
      try await Task.sleep(for: delay)
      try await connect()
    } catch {
      emit(.transportError("Reconnect failed: \(error.localizedDescription)"))
    }
  }

  private func startHeartbeatLoop() {
    heartbeatTask?.cancel()
    heartbeatTask = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: heartbeatInterval)
        } catch {
          return
        }

        if pendingHeartbeatRef != nil {
          pendingHeartbeatRef = nil
          transport?.disconnect(code: 1000, reason: "heartbeat timeout")
          continue
        }

        let ref = makeRef()
        pendingHeartbeatRef = ref
        let frame = SocketFrame(joinRef: nil, ref: ref, topic: "phoenix", event: PhoenixSystemEvent.heartbeat.rawValue, payload: [:])
        try? sendOrBuffer(frame)
      }
    }
  }

  private func sendOrBuffer(_ frame: SocketFrame) throws {
    guard let transport, transport.readyState == .open else {
      sendBuffer.append(frame)
      return
    }

    let data: Data
    do {
      data = try Defaults.encodeFrame(frame)
    } catch {
      throw PhoenixError.encodingFailure(error.localizedDescription)
    }
    transport.send(data: data)
  }

  private func flushSendBuffer() {
    let buffered = sendBuffer
    sendBuffer.removeAll()
    buffered.forEach { try? sendOrBuffer($0) }
  }

  private func makeRef() -> String {
    nextRefCounter = (nextRefCounter == UInt64.max) ? 0 : nextRefCounter + 1
    return String(nextRefCounter)
  }

  private static func buildEndpointURL(endpoint: String, paramsClosure: PayloadClosure?, vsn: String) throws -> URL {
    guard let url = URL(string: endpoint), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw PhoenixError.malformedEndpoint(endpoint)
    }

    if !components.path.contains("/websocket") {
      if components.path.last != "/" { components.path.append("/") }
      components.path.append("websocket")
    }

    components.queryItems = [URLQueryItem(name: "vsn", value: vsn)]
    if let params = paramsClosure?() {
      components.queryItems?.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value.queryValue) })
    }

    guard let qualified = components.url else {
      throw PhoenixError.malformedEndpoint(endpoint)
    }
    return qualified
  }

  // MARK: Continuation helpers
  private func registerReplyWaiter(ref: String, continuation: CheckedContinuation<PhoenixMessage, Error>) async {
    replyWaiters[ref] = continuation
  }

  private func registerGlobalContinuation(_ continuation: AsyncStream<ClientEvent>.Continuation, id: UUID) async {
    globalContinuations[id] = continuation
  }

  private func unregisterGlobalContinuation(id: UUID) async {
    globalContinuations[id] = nil
  }

  private func registerTopicContinuation(_ continuation: AsyncStream<PhoenixMessage>.Continuation, id: UUID, topic: String) async {
    var topicMap = topicContinuations[topic] ?? [:]
    topicMap[id] = continuation
    topicContinuations[topic] = topicMap
  }

  private func unregisterTopicContinuation(id: UUID, topic: String) async {
    topicContinuations[topic]?[id] = nil
    if topicContinuations[topic]?.isEmpty == true {
      topicContinuations[topic] = nil
    }
  }

  private func emit(_ event: ClientEvent) {
    globalContinuations.values.forEach { $0.yield(event) }
  }

  private func emitTopic(_ message: PhoenixMessage) {
    topicContinuations[message.topic]?.values.forEach { $0.yield(message) }
  }
}
