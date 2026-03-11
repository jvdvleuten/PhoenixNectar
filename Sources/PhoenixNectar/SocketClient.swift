import Foundation
#if canImport(OSLog)
import OSLog
#else
public enum OSLogType: Sendable {
  case debug
  case info
  case notice
  case error
  case fault
}

public struct Logger: Sendable {
  public init(subsystem: String, category: String) {}
  public func debug(_ message: @autoclosure () -> String) {}
  public func info(_ message: @autoclosure () -> String) {}
  public func notice(_ message: @autoclosure () -> String) {}
  public func error(_ message: @autoclosure () -> String) {}
}
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor ReconnectPolicyState {
  private var attempts: Int = 0

  func reset() {
    attempts = 0
  }

  func nextAttempt() -> Int {
    attempts += 1
    return attempts
  }
}

private actor ConnectionStateHub {
  private var currentState: ConnectionState = .idle
  private var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

  func register(_ continuation: AsyncStream<ConnectionState>.Continuation, id: UUID) {
    continuations[id] = continuation
    continuation.yield(currentState)
  }

  func unregister(id: UUID) {
    continuations[id] = nil
  }

  func set(_ state: ConnectionState) {
    currentState = state
    continuations.values.forEach { $0.yield(state) }
  }

  func finishAll() {
    continuations.values.forEach { $0.finish() }
    continuations.removeAll()
  }
}

/// Multiplexes values to per-topic async stream subscribers.
///
/// Continuations use the buffering policy chosen by each subscriber. With the default
/// `.unbounded` policy, a slow consumer can accumulate unbounded memory. Callers should
/// pass an explicit policy (e.g. `.bufferingNewest(n)`) to cap memory usage when high
/// throughput is expected.
private actor TopicStreamHub<T: Sendable> {
  private var continuations: [String: [UUID: AsyncStream<T>.Continuation]] = [:]

  func register(
    topic: String,
    continuation: AsyncStream<T>.Continuation,
    id: UUID
  ) {
    var topicMap = continuations[topic, default: [:]]
    topicMap[id] = continuation
    continuations[topic] = topicMap
  }

  func unregister(topic: String, id: UUID) {
    guard var topicMap = continuations[topic] else { return }
    topicMap[id] = nil
    if topicMap.isEmpty {
      continuations[topic] = nil
    } else {
      continuations[topic] = topicMap
    }
  }

  func emit(topic: String, _ value: T) {
    continuations[topic]?.values.forEach { $0.yield(value) }
  }

  func finishAll() {
    continuations.values.forEach { topicMap in
      topicMap.values.forEach { $0.finish() }
    }
    continuations.removeAll()
  }
}

private struct BufferedTextOperation: Sendable {
  let ref: String
  let frame: SocketFrame
  let topic: Topic
  let event: PhoenixEvent
}

private struct BufferedBinaryOperation: Sendable {
  let ref: String
  let data: Data
  let topic: Topic
  let event: PhoenixEvent
}

/// Actor that owns socket lifecycle, reconnect behavior, and channel intent for one Phoenix endpoint.
public actor Socket {
  /// Immutable runtime settings for one socket client instance.
  public struct Configuration: Sendable {
    public let vsn: String
    public let headers: [String: String]
    public let defaultRequestPolicy: RequestPolicy
    public let connectionPolicy: ConnectionPolicy
    public let outboundBufferLimit: Int
    public let binaryOutboundBufferLimit: Int
    public let bufferOverflowPolicy: BufferOverflowPolicy

    public init(
      vsn: String = "2.0.0",
      headers: [String: String] = [:],
      defaultRequestPolicy: RequestPolicy = .default,
      connectionPolicy: ConnectionPolicy = .default,
      outboundBufferLimit: Int = 512,
      binaryOutboundBufferLimit: Int = 128,
      bufferOverflowPolicy: BufferOverflowPolicy = .dropOldest
    ) {
      self.vsn = vsn
      self.headers = headers
      self.defaultRequestPolicy = defaultRequestPolicy
      self.connectionPolicy = connectionPolicy
      self.outboundBufferLimit = outboundBufferLimit
      self.binaryOutboundBufferLimit = binaryOutboundBufferLimit
      self.bufferOverflowPolicy = bufferOverflowPolicy
    }

    public static let `default` = Configuration()
  }

  public let endpoint: String
  public let vsn: String
  private var configuration: Configuration
  private var logger: Logger?
  private var metricsHook: ClientMetricsHook?
  private var logSink: (@Sendable (OSLogType, String, String, [String: String]) -> Void)?

  private let connectParamsProvider: (@Sendable () throws -> Payload?)?
  private let authTokenProvider: AuthTokenProvider?
  private let transportFactory: @Sendable (URL) -> any PhoenixTransport
  private let reconnectState = ReconnectPolicyState()
  private let stateHub = ConnectionStateHub()
  private let topicHub = TopicStreamHub<PhoenixMessage>()
  private let binaryTopicHub = TopicStreamHub<PhoenixBinaryMessage>()
  private let scheduler: PhoenixScheduler

  private var endpointURL: URL
  private var transport: (any PhoenixTransport)?
  private var transportTask: Task<Void, Never>?
  private var heartbeatToken: PhoenixSchedulerToken?
  private var reconnectToken: PhoenixSchedulerToken?
  private var rejoinRetryToken: PhoenixSchedulerToken?
  private var terminalTransportEventHandled = false

  private var nextRefCounter: UInt64 = 0
  private var pendingHeartbeatRef: String?
  private var bufferedTextOperations: [String: BufferedTextOperation] = [:]
  private var bufferedTextOrder: [String] = []
  private var bufferedBinaryOperations: [String: BufferedBinaryOperation] = [:]
  private var bufferedBinaryOrder: [String] = []

  private var replyWaiters: [String: CheckedContinuation<PhoenixReply, Error>] = [:]
  private var replyTimeoutTasks: [String: Task<Void, Never>] = [:]
  private var channelJoinRefs: [String: String] = [:]
  private var desiredChannelParams: [String: Payload] = [:]
  private var rejoinTask: Task<Void, Never>?
  private var pendingRejoinOnOpen: Bool = false
  private var rejoinAttempt: Int = 0

  /// Cancels runtime tasks and sends a best-effort close frame.
  ///
  /// The disconnect runs in an unstructured `Task` because `deinit` is synchronous.
  /// If the transport is already torn down the close frame is silently dropped,
  /// and the server may observe an abrupt TCP close instead of a clean WebSocket close.
  /// Prefer calling ``disconnect(code:reason:)`` explicitly before releasing the socket.
  deinit {
    transportTask?.cancel()
    rejoinTask?.cancel()
    if let transport {
      Task {
        await transport.disconnect(code: 1000, reason: "socket deinit")
      }
    }
  }

  /// Creates a client with dynamic connect params and optional auth token providers.
  public init(
    endpoint: String,
    configuration: Configuration = .default,
    authTokenProvider: AuthTokenProvider? = nil
  ) throws {
    try self.init(
      endpoint: endpoint,
      configuration: configuration,
      connectParamsProvider: nil,
      authTokenProvider: authTokenProvider,
      scheduler: ClockScheduler(),
      transportFactory: { URLSessionTransport(url: $0) }
    )
  }

  /// Creates a client with typed connect params evaluated on connect and reconnect.
  public init<ConnectParams: Encodable & Sendable>(
    endpoint: String,
    configuration: Configuration = .default,
    connectParamsProvider: @escaping @Sendable () -> ConnectParams?,
    authTokenProvider: AuthTokenProvider? = nil
  ) throws {
    try self.init(
      endpoint: endpoint,
      configuration: configuration,
      connectParamsProvider: {
        guard let params = connectParamsProvider() else { return nil }
        let encoded = try PhoenixValue.fromEncodable(params)
        guard case .object(let object) = encoded else {
          throw PhoenixError.encodingFailure("Encoded connect params are not a JSON object")
        }
        return object
      },
      authTokenProvider: authTokenProvider,
      scheduler: ClockScheduler(),
      transportFactory: { URLSessionTransport(url: $0) }
    )
  }

  init(
    endpoint: String,
    configuration: Configuration = .default,
    connectParamsProvider: (@Sendable () throws -> Payload?)? = nil,
    authTokenProvider: AuthTokenProvider? = nil,
    scheduler: PhoenixScheduler = ClockScheduler(),
    transportFactory: @escaping @Sendable (URL) -> any PhoenixTransport = { URLSessionTransport(url: $0) }
  ) throws {
    self.endpoint = endpoint
    self.connectParamsProvider = connectParamsProvider
    self.authTokenProvider = authTokenProvider
    self.vsn = configuration.vsn
    self.configuration = configuration
    self.scheduler = scheduler
    self.transportFactory = transportFactory
    self.endpointURL = try Self.buildEndpointURL(
      endpoint: endpoint,
      connectParamsProvider: connectParamsProvider,
      vsn: configuration.vsn
    )
  }

  public var headers: [String: String] { configuration.headers }
  public var defaultRequestPolicy: RequestPolicy { configuration.defaultRequestPolicy }
  public var connectionPolicy: ConnectionPolicy { configuration.connectionPolicy }
  public var outboundBufferLimit: Int { configuration.outboundBufferLimit }
  public var binaryOutboundBufferLimit: Int { configuration.binaryOutboundBufferLimit }
  public var bufferOverflowPolicy: BufferOverflowPolicy { configuration.bufferOverflowPolicy }

  public func setLogger(_ logger: Logger?) {
    self.logger = logger
  }

  public func setMetricsHook(_ metricsHook: ClientMetricsHook?) {
    self.metricsHook = metricsHook
  }

  func setLogSink(_ logSink: (@Sendable (OSLogType, String, String, [String: String]) -> Void)?) {
    self.logSink = logSink
  }

  func replaceConfiguration(_ configuration: Configuration) {
    self.configuration = configuration
  }

  /// Opens the socket transport and starts the runtime loops.
  public func connect() async throws {
    log(.info, category: "transport", message: "connect requested", metadata: ["endpoint": endpoint])
    try await connect(resetReconnectState: true)
  }

  /// Intentionally disconnects the socket and clears desired channel state.
  public func disconnect(code: Int = 1000, reason: String? = nil) async {
    log(
      .info,
      category: "transport",
      message: "disconnect requested",
      metadata: ["code": String(code), "reason": reason ?? ""]
    )
    terminalTransportEventHandled = true
    scheduler.cancel(heartbeatToken)
    heartbeatToken = nil
    scheduler.cancel(reconnectToken)
    reconnectToken = nil
    scheduler.cancel(rejoinRetryToken)
    rejoinRetryToken = nil

    transportTask?.cancel()
    transportTask = nil

    if let transport {
      await transport.disconnect(code: code, reason: reason)
    }
    self.transport = nil
    rejoinTask?.cancel()
    rejoinTask = nil
    pendingHeartbeatRef = nil
    clearAllBufferedOperations()

    await reconnectState.reset()
    channelJoinRefs.removeAll()
    desiredChannelParams.removeAll()
    failAllReplyWaiters(with: PhoenixError.channelClosed("socket"))
    await setState(.disconnected(code: code, reason: reason))
    await topicHub.finishAll()
    await binaryTopicHub.finishAll()
    await stateHub.finishAll()
  }

  /// Creates a handle for a topic without joining it.
  func channel(_ topic: Topic) -> Channel {
    Channel(topic: topic, params: [:], client: self)
  }

  /// Creates a handle from a precomposed channel descriptor without joining it.
  func channel(_ descriptor: ChannelDescriptor) -> Channel {
    Channel(topic: descriptor.topic, params: descriptor.params, client: self)
  }

  /// Returns a stream of connection lifecycle states, starting with the current state.
  public func connectionStateStream(
    bufferingPolicy: AsyncStream<ConnectionState>.Continuation.BufferingPolicy = .bufferingNewest(1)
  ) async -> AsyncStream<ConnectionState> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: bufferingPolicy)
    await stateHub.register(continuation, id: id)
    continuation.onTermination = { _ in
      Task { [weak self] in
        await self?.stateHub.unregister(id: id)
      }
    }
    return stream
  }

  /// Joins a topic and returns the resulting channel handle.
  public func joinChannel(
    _ topic: String,
    policy: RequestPolicy = .default
  ) async throws -> Channel {
    let handle = Channel(topic: Topic(topic), params: [:], client: self)
    _ = try await handle.join(policy: policy)
    return handle
  }

  /// Joins a descriptor and returns the resulting channel handle.
  func joinChannel(
    _ descriptor: ChannelDescriptor,
    policy: RequestPolicy = .default
  ) async throws -> Channel {
    try await joinChannel(descriptor.topic, params: descriptor.params, policy: policy)
  }

  /// Joins a topic using an encodable params object.
  public func joinChannel<T: Encodable>(
    _ topic: String,
    params: T,
    policy: RequestPolicy = .default
  ) async throws -> Channel {
    let payloadValue = try PhoenixValue.fromEncodable(params)
    guard case .object(let object) = payloadValue else {
      throw PhoenixError.encodingFailure("Encoded join payload is not a JSON object")
    }
    return try await joinChannel(Topic(topic), payload: object, policy: policy)
  }

  public func joinChannel(
    _ topic: Topic,
    policy: RequestPolicy = .default
  ) async throws -> Channel {
    try await joinChannel(topic.rawValue, policy: policy)
  }

  public func joinChannel<T: Encodable>(
    _ topic: Topic,
    params: T,
    policy: RequestPolicy = .default
  ) async throws -> Channel {
    try await joinChannel(topic.rawValue, params: params, policy: policy)
  }

  private func joinChannel(
    _ topic: Topic,
    payload: Payload,
    policy: RequestPolicy = .default
  ) async throws -> Channel {
    let handle = Channel(topic: topic, params: payload, client: self)
    _ = try await handle.join(policy: policy)
    return handle
  }

  func messages(
    topic: Topic,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncStream<PhoenixMessage> {
    let (stream, _) = await makeMessagesStream(rawTopic: topic.rawValue, bufferingPolicy: bufferingPolicy)
    return stream
  }

  /// Measures a heartbeat round trip using the supplied request policy.
  public func ping(policy: RequestPolicy = .default) async throws -> Duration {
    let clock = ContinuousClock()
    let start = clock.now

    _ = try await pushRaw(
      topic: "phoenix",
      event: .system(.heartbeat),
      payload: [:],
      joinRef: nil,
      policy: policy
    )
    return start.duration(to: clock.now)
  }

  // MARK: Channel Operations
  func join(topic: Topic, params: Payload, policy: RequestPolicy) async throws -> PhoenixReply {
    let key = topic.rawValue
    desiredChannelParams[key] = params
    let joinRef = makeRef()
    channelJoinRefs[key] = joinRef
    log(.info, category: "channel", message: "join", metadata: ["topic": key, "joinRef": joinRef])

    do {
      return try await pushRaw(topic: key, event: .system(.join), payload: params, joinRef: joinRef, policy: policy)
    } catch {
      desiredChannelParams[key] = nil
      channelJoinRefs[key] = nil
      throw error
    }
  }

  func leave(topic: Topic, policy: RequestPolicy) async throws -> PhoenixReply {
    let key = topic.rawValue
    log(.info, category: "channel", message: "leave", metadata: ["topic": key])
    defer {
      channelJoinRefs.removeValue(forKey: key)
      desiredChannelParams.removeValue(forKey: key)
    }
    let joinRef = channelJoinRefs[key]
    return try await pushRaw(topic: key, event: .system(.leave), payload: [:], joinRef: joinRef, policy: policy)
  }

  func push(
    topic: Topic,
    event: PhoenixEvent,
    payload: Payload,
    policy: RequestPolicy
  ) async throws -> PhoenixReply {
    let key = topic.rawValue
    return try await pushRaw(topic: key, event: event, payload: payload, joinRef: channelJoinRefs[key], policy: policy)
  }

  func pushBinary(
    topic: Topic,
    event: PhoenixEvent,
    data: Data,
    policy: RequestPolicy
  ) async throws -> PhoenixReply {
    let key = topic.rawValue
    let ref = makeRef()
    let joinRef = channelJoinRefs[key] ?? ""
    let frameData = try Self.binaryPushFrame(
      joinRef: joinRef,
      ref: ref,
      topic: key,
      event: event.rawValue,
      payload: data
    )
    return try await awaitReply(for: ref, policy: policy) { [weak self] in
      try await self?.sendOrBufferBinary(frameData, ref: ref, topic: topic, event: event)
    }
  }

  // MARK: Transport
  private func connect(resetReconnectState: Bool) async throws {
    if let transport {
      let current = await transport.readyState()
      guard current != .open && current != .connecting else { return }
    }

    if resetReconnectState {
      await reconnectState.reset()
      pendingRejoinOnOpen = false
    }

    terminalTransportEventHandled = false
    await setState(.connecting)
    endpointURL = try Self.buildEndpointURL(endpoint: endpoint, connectParamsProvider: connectParamsProvider, vsn: vsn)

    let transport = transportFactory(endpointURL)
    self.transport = transport

    await consumeTransportEvents(transport)

    var connectionHeaders = configuration.headers
    if let authToken = authTokenProvider?() {
      connectionHeaders["Sec-WebSocket-Protocol"] = Self.websocketProtocolsHeader(authToken: authToken)
    }

    await transport.connect(with: connectionHeaders)
  }

  private func consumeTransportEvents(_ transport: any PhoenixTransport) async {
    transportTask?.cancel()
    let stream = await transport.events(bufferingPolicy: .unbounded)
    transportTask = Task { [weak self] in
      for await event in stream {
        guard let self else { return }
        await self.handleTransportEvent(event)
      }
    }
  }

  private func handleTransportEvent(_ event: TransportEvent) async {
    emitMetric(.transport(event))
    logTransportEvent(event)

    switch event {
    case .open:
      terminalTransportEventHandled = false
      await reconnectState.reset()
      await setState(.connected)
      await flushSendBuffer()
      startHeartbeatLoop()
      rejoinAttempt = 0
      if pendingRejoinOnOpen {
        pendingRejoinOnOpen = false
        startRejoinLoop()
      }

    case .message(let raw):
      guard let data = raw.data(using: .utf8) else { return }

      do {
        let frame = try Defaults.decodeFrame(data)
        let message = PhoenixMessage(frame: frame)
        emitMetric(.frameReceived(message))
        log(
          .debug,
          category: "receive",
          message: "text frame received",
          metadata: ["topic": message.topic.rawValue, "event": message.event.rawValue, "ref": message.ref ?? ""]
        )

        if let pending = pendingHeartbeatRef, pending == message.ref {
          pendingHeartbeatRef = nil
        }

        if case .system(.reply) = message.event, let ref = message.ref {
          do {
            let reply = try message.replyEnvelope()
            finishReplyWaiter(ref: ref, with: .success(reply))
          } catch {
            finishReplyWaiter(ref: ref, with: .failure(error))
          }
        }

        if shouldEmitTextMessage(message) {
          await emitTopic(message)
        }
      } catch {
        await handleTerminalTransportFailure(
          state: .failed((error as? PhoenixError) ?? .protocolViolation(error.localizedDescription)),
          trigger: .error(error.localizedDescription)
        )
      }

    case .messageData(let data):
      do {
        switch try Self.binaryFrameKind(from: data) {
        case 1:
          let reply = try Self.binaryReply(from: data)
          log(
            .debug,
            category: "receive",
            message: "binary reply received",
            metadata: ["topic": reply.topic.rawValue, "ref": reply.ref]
          )
          finishReplyWaiter(ref: reply.ref, with: .success(reply))
        case 0, 2:
          if let message = try Self.binaryMessage(from: data) {
            log(
              .debug,
              category: "receive",
              message: "binary frame received",
              metadata: ["topic": message.topic.rawValue, "event": message.event.rawValue, "ref": message.ref ?? ""]
            )
            if shouldEmitBinaryMessage(message) {
              await emitBinaryTopic(message)
            }
          }
        default:
          throw PhoenixError.protocolViolation("Unsupported binary frame kind")
        }
      } catch {
        await handleTerminalTransportFailure(
          state: .failed((error as? PhoenixError) ?? .protocolViolation(error.localizedDescription)),
          trigger: .error(error.localizedDescription)
        )
      }

    case .close(let code, let reason):
      await handleTerminalTransportFailure(
        state: .disconnected(code: code, reason: reason),
        trigger: .close(code)
      )

    case .error(let error):
      await handleTerminalTransportFailure(
        state: .failed(.protocolViolation(error)),
        trigger: .error(error)
      )
    }
  }

  private enum ReconnectTrigger {
    case close(Int)
    case error(String)
  }

  private func handleTerminalTransportFailure(
    state: ConnectionState,
    trigger: ReconnectTrigger?
  ) async {
    guard !terminalTransportEventHandled else { return }
    terminalTransportEventHandled = true

    scheduler.cancel(heartbeatToken)
    heartbeatToken = nil
    scheduler.cancel(rejoinRetryToken)
    rejoinRetryToken = nil
    rejoinTask?.cancel()
    rejoinTask = nil
    if let pendingHeartbeatRef {
      removeBufferedOperation(for: pendingHeartbeatRef)
      self.pendingHeartbeatRef = nil
    }

    transport = nil
    transportTask?.cancel()
    transportTask = nil
    failAllReplyWaiters(with: PhoenixError.channelClosed("socket"))
    await setState(state)
    await topicHub.finishAll()
    await binaryTopicHub.finishAll()

    if let trigger {
      await scheduleReconnectIfNeeded(trigger: trigger)
    }
  }

  private func scheduleReconnectIfNeeded(trigger: ReconnectTrigger) async {
    switch trigger {
    case .close(let code) where code == 1000:
      guard configuration.connectionPolicy.reconnectOnCleanClose else { return }
    default:
      break
    }

    let attempt = await reconnectState.nextAttempt()
    let delay = configuration.connectionPolicy.reconnectBackoff(attempt)
    await setState(.reconnecting(attempt: attempt, delay: delay))
    pendingRejoinOnOpen = true
    scheduler.cancel(reconnectToken)
    reconnectToken = scheduler.scheduleOnce(after: Self.seconds(from: delay), tolerance: nil) { [weak self] in
      guard let self else { return }
      do {
        try await self.connect(resetReconnectState: false)
      } catch {
        await self.setState(.failed(.protocolViolation("Reconnect failed: \(error.localizedDescription)")))
      }
    }
  }

  private func startHeartbeatLoop() {
    scheduler.cancel(heartbeatToken)
    heartbeatToken = scheduler.scheduleRepeating(
      every: Self.seconds(from: configuration.connectionPolicy.heartbeatInterval),
      tolerance: nil
    ) { [weak self] in
      guard let self else { return }
      if await self.hasPendingHeartbeatRef() {
        await self.clearPendingHeartbeatAndDisconnect()
        return
      }

      let ref = await self.makeRef()
      await self.setPendingHeartbeatRef(ref)

      let frame = SocketFrame(
        joinRef: nil,
        ref: ref,
        topic: "phoenix",
        event: PhoenixSystemEvent.heartbeat.rawValue,
        payload: [:]
      )
      try? await self.sendOrBuffer(frame)
    }
  }

  private func startRejoinLoop() {
    rejoinTask?.cancel()
    rejoinTask = Task { [weak self] in
      await self?.rejoinDesiredChannels()
    }
  }

  private func rejoinDesiredChannels() async {
    let snapshot = desiredChannelParams
    if snapshot.isEmpty { return }
    var hadFailure = false

    for (topic, params) in snapshot {
      guard !Task.isCancelled else { return }

      let joinRef = makeRef()
      channelJoinRefs[topic] = joinRef

      do {
        _ = try await pushRaw(
          topic: topic,
          event: .system(.join),
          payload: params,
          joinRef: joinRef,
          policy: configuration.defaultRequestPolicy
        )
      } catch {
        channelJoinRefs[topic] = nil
        hadFailure = true
      }
    }

    if hadFailure {
      scheduleRejoinRetry()
    } else {
      rejoinAttempt = 0
      scheduler.cancel(rejoinRetryToken)
      rejoinRetryToken = nil
    }
  }

  private func scheduleRejoinRetry() {
    rejoinAttempt += 1
    let delay = configuration.connectionPolicy.reconnectBackoff(rejoinAttempt)
    scheduler.cancel(rejoinRetryToken)
    rejoinRetryToken = scheduler.scheduleOnce(after: Self.seconds(from: delay), tolerance: nil) { [weak self] in
      await self?.startRejoinLoop()
    }
  }

  private func pushRaw(
    topic: String,
    event: PhoenixEvent,
    payload: Payload,
    joinRef: String?,
    policy: RequestPolicy
  ) async throws -> PhoenixReply {
    var lastError: Error?
    let maxAttempts = max(policy.retries, 0) + 1

    for attempt in 0..<maxAttempts {
      let ref = makeRef()
      let frame = SocketFrame(joinRef: joinRef, ref: ref, topic: topic, event: event.rawValue, payload: payload)

      do {
        let reply = try await awaitReply(for: ref, policy: policy) { [weak self] in
          try await self?.sendOrBuffer(frame)
        }

        switch reply.status {
        case .ok:
          return reply
        case .error:
          throw PhoenixError.serverError(reply)
        case .timeout:
          throw PhoenixError.timeout
        }
      } catch {
        lastError = error
        if !Self.isRetryablePushError(error) {
          throw error
        }
        if attempt < maxAttempts - 1 {
          let backoff = policy.retryBackoff(attempt + 1)
          if backoff > .zero {
            try await Task.sleep(for: backoff)
          }
          continue
        }
      }
    }

    throw lastError ?? PhoenixError.timeout
  }

  private static func isRetryablePushError(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    guard let phoenixError = error as? PhoenixError else { return false }
    switch phoenixError {
    case .timeout, .notConnected, .channelClosed:
      return true
    case .bufferOverflow, .serverError, .protocolViolation, .encodingFailure, .decodingFailure, .malformedEndpoint:
      return false
    }
  }

  private func awaitReply(
    for ref: String,
    policy: RequestPolicy,
    send: @escaping @Sendable () async throws -> Void
  ) async throws -> PhoenixReply {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        replyWaiters[ref] = continuation
        awaitSendOrResume(send: send, ref: ref, timeout: policy.timeout)
      }
    } onCancel: {
      Task { await self.finishReplyWaiter(ref: ref, with: .failure(CancellationError())) }
    }
  }

  private func awaitSendOrResume(
    send: @escaping @Sendable () async throws -> Void,
    ref: String,
    timeout: Duration
  ) {
    Task {
      do {
        try await send()
      } catch {
        self.finishReplyWaiter(ref: ref, with: .failure(error))
        return
      }

      let timeoutTask = Task { [weak self] in
        do {
          try await Task.sleep(for: timeout)
          await self?.emitMetric(.pushTimedOut(ref: ref))
          await self?.finishReplyWaiter(ref: ref, with: .failure(PhoenixError.timeout))
        } catch {
          return
        }
      }

      self.setTimeoutTask(timeoutTask, for: ref)
    }
  }

  private func setTimeoutTask(_ task: Task<Void, Never>, for ref: String) {
    if let existing = replyTimeoutTasks[ref] {
      existing.cancel()
    }
    replyTimeoutTasks[ref] = task
  }

  private func finishReplyWaiter(ref: String, with result: Result<PhoenixReply, Error>) {
    removeBufferedOperation(for: ref)
    guard let continuation = replyWaiters.removeValue(forKey: ref) else { return }

    if let timeoutTask = replyTimeoutTasks.removeValue(forKey: ref) {
      timeoutTask.cancel()
    }

    continuation.resume(with: result)
  }

  private func failAllReplyWaiters(with error: Error) {
    let refs = Array(replyWaiters.keys)
    refs.forEach { ref in
      finishReplyWaiter(ref: ref, with: .failure(error))
    }
  }

  private func sendOrBuffer(_ frame: SocketFrame) async throws {
    let topic = Topic(frame.topic)
    let event = PhoenixEvent(rawValue: frame.event)

    guard let transport else {
      if event == .system(.heartbeat) {
        throw PhoenixError.notConnected
      }
      try bufferTextOperation(
        BufferedTextOperation(
          ref: try bufferRef(for: frame.ref, kind: "text"),
          frame: frame,
          topic: topic,
          event: event
        )
      )
      emitMetric(.frameBuffered(ref: frame.ref, topic: topic, event: event))
      return
    }

    let state = await transport.readyState()
    guard state == .open else {
      if event == .system(.heartbeat) {
        throw PhoenixError.notConnected
      }
      try bufferTextOperation(
        BufferedTextOperation(
          ref: try bufferRef(for: frame.ref, kind: "text"),
          frame: frame,
          topic: topic,
          event: event
        )
      )
      emitMetric(.frameBuffered(ref: frame.ref, topic: topic, event: event))
      return
    }

    let data: Data
    do {
      data = try Defaults.encodeFrame(frame)
    } catch {
      throw PhoenixError.encodingFailure(error.localizedDescription)
    }

    await transport.sendText(data: data)
    emitMetric(.frameSent(ref: frame.ref, topic: topic, event: event))
    log(
      .debug,
      category: "send",
      message: "text frame sent",
      metadata: ["topic": topic.rawValue, "event": event.rawValue, "ref": frame.ref ?? ""]
    )
  }

  private func sendOrBufferBinary(
    _ data: Data,
    ref: String,
    topic: Topic,
    event: PhoenixEvent
  ) async throws {
    guard let transport else {
      try bufferBinaryOperation(
        BufferedBinaryOperation(ref: ref, data: data, topic: topic, event: event)
      )
      return
    }

    let state = await transport.readyState()
    guard state == .open else {
      try bufferBinaryOperation(
        BufferedBinaryOperation(ref: ref, data: data, topic: topic, event: event)
      )
      return
    }

    await transport.sendBinary(data: data)
    log(
      .debug,
      category: "send",
      message: "binary frame sent",
      metadata: ["topic": topic.rawValue, "event": event.rawValue, "ref": ref]
    )
  }

  private func flushSendBuffer() async {
    let bufferedText = bufferedTextOrder.compactMap { ref -> BufferedTextOperation? in
      defer { bufferedTextOperations[ref] = nil }
      return bufferedTextOperations[ref]
    }
    bufferedTextOrder.removeAll()

    for operation in bufferedText {
      try? await sendOrBuffer(operation.frame)
    }

    let bufferedBinary = bufferedBinaryOrder.compactMap { ref -> BufferedBinaryOperation? in
      defer { bufferedBinaryOperations[ref] = nil }
      return bufferedBinaryOperations[ref]
    }
    bufferedBinaryOrder.removeAll()
    for operation in bufferedBinary {
      try? await sendOrBufferBinary(
        operation.data,
        ref: operation.ref,
        topic: operation.topic,
        event: operation.event
      )
    }
  }

  private func bufferRef(for ref: String?, kind: String) throws -> String {
    guard let ref else {
      throw PhoenixError.protocolViolation("Buffered \(kind) operation is missing ref")
    }
    return ref
  }

  private func bufferTextOperation(_ operation: BufferedTextOperation) throws {
    let limit = max(0, configuration.outboundBufferLimit)
    guard limit > 0 else {
      emitMetric(.frameDropped(ref: operation.ref, topic: operation.topic, event: operation.event))
      throw PhoenixError.bufferOverflow("text buffer disabled")
    }

    if bufferedTextOperations[operation.ref] != nil {
      bufferedTextOperations[operation.ref] = operation
      return
    }

    if bufferedTextOrder.count >= limit {
      switch configuration.bufferOverflowPolicy {
      case .dropOldest:
        if let oldestRef = bufferedTextOrder.first {
          dropBufferedTextOperation(ref: oldestRef)
        }
      case .dropNewest:
        emitMetric(.frameDropped(ref: operation.ref, topic: operation.topic, event: operation.event))
        throw PhoenixError.bufferOverflow("text buffer full")
      }
    }

    bufferedTextOperations[operation.ref] = operation
    bufferedTextOrder.append(operation.ref)
  }

  private func bufferBinaryOperation(_ operation: BufferedBinaryOperation) throws {
    let limit = max(0, configuration.binaryOutboundBufferLimit)
    guard limit > 0 else {
      emitMetric(.frameDropped(ref: operation.ref, topic: operation.topic, event: operation.event))
      throw PhoenixError.bufferOverflow("binary buffer disabled")
    }

    if bufferedBinaryOperations[operation.ref] != nil {
      bufferedBinaryOperations[operation.ref] = operation
      return
    }

    if bufferedBinaryOrder.count >= limit {
      switch configuration.bufferOverflowPolicy {
      case .dropOldest:
        if let oldestRef = bufferedBinaryOrder.first {
          dropBufferedBinaryOperation(ref: oldestRef)
        }
      case .dropNewest:
        emitMetric(.frameDropped(ref: operation.ref, topic: operation.topic, event: operation.event))
        throw PhoenixError.bufferOverflow("binary buffer full")
      }
    }

    bufferedBinaryOperations[operation.ref] = operation
    bufferedBinaryOrder.append(operation.ref)
  }

  private func removeBufferedOperation(for ref: String) {
    if bufferedTextOperations.removeValue(forKey: ref) != nil {
      if let index = bufferedTextOrder.firstIndex(of: ref) {
        bufferedTextOrder.remove(at: index)
      }
    }

    if bufferedBinaryOperations.removeValue(forKey: ref) != nil {
      if let index = bufferedBinaryOrder.firstIndex(of: ref) {
        bufferedBinaryOrder.remove(at: index)
      }
    }
  }

  private func clearAllBufferedOperations() {
    bufferedTextOperations.removeAll()
    bufferedTextOrder.removeAll()
    bufferedBinaryOperations.removeAll()
    bufferedBinaryOrder.removeAll()
  }

  private func dropBufferedTextOperation(ref: String) {
    guard let operation = bufferedTextOperations.removeValue(forKey: ref) else { return }
    if let index = bufferedTextOrder.firstIndex(of: ref) {
      bufferedTextOrder.remove(at: index)
    }
    emitMetric(.frameDropped(ref: operation.ref, topic: operation.topic, event: operation.event))
    if replyWaiters[ref] != nil {
      finishReplyWaiter(ref: ref, with: .failure(PhoenixError.bufferOverflow("text buffer full")))
    }
  }

  private func dropBufferedBinaryOperation(ref: String) {
    guard let operation = bufferedBinaryOperations.removeValue(forKey: ref) else { return }
    if let index = bufferedBinaryOrder.firstIndex(of: ref) {
      bufferedBinaryOrder.remove(at: index)
    }
    emitMetric(.frameDropped(ref: operation.ref, topic: operation.topic, event: operation.event))
    if replyWaiters[ref] != nil {
      finishReplyWaiter(ref: ref, with: .failure(PhoenixError.bufferOverflow("binary buffer full")))
    }
  }

  private func makeRef() -> String {
    nextRefCounter = (nextRefCounter == UInt64.max) ? 0 : nextRefCounter + 1
    return String(nextRefCounter)
  }

  private static func buildEndpointURL(
    endpoint: String,
    connectParamsProvider: (@Sendable () throws -> Payload?)?,
    vsn: String
  ) throws -> URL {
    guard let url = URL(string: endpoint), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw PhoenixError.malformedEndpoint(endpoint)
    }

    if !components.path.contains("/websocket") {
      if components.path.last != "/" { components.path.append("/") }
      components.path.append("websocket")
    }

    components.queryItems = [URLQueryItem(name: "vsn", value: vsn)]
    if let params = try connectParamsProvider?() {
      components.queryItems?.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value.queryValue) })
    }

    guard let qualified = components.url else {
      throw PhoenixError.malformedEndpoint(endpoint)
    }
    return qualified
  }

  private static func websocketProtocolsHeader(authToken: String) -> String {
    "phoenix, \(authTokenSubprotocol(authToken: authToken))"
  }

  private static func authTokenSubprotocol(authToken: String) -> String {
    let encoded = Data(authToken.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "base64url.bearer.phx.\(encoded)"
  }

  private static func seconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
  }

  private static func binaryPushFrame(
    joinRef: String,
    ref: String,
    topic: String,
    event: String,
    payload: Data
  ) throws -> Data {
    let joinRefBytes = Array(joinRef.utf8)
    let refBytes = Array(ref.utf8)
    let topicBytes = Array(topic.utf8)
    let eventBytes = Array(event.utf8)
    guard joinRefBytes.count <= 255, refBytes.count <= 255, topicBytes.count <= 255, eventBytes.count <= 255 else {
      throw PhoenixError.protocolViolation("Binary frame fields exceed 255-byte serializer limit")
    }

    var data = Data()
    data.append(0) // kind: push
    data.append(UInt8(joinRefBytes.count))
    data.append(UInt8(refBytes.count))
    data.append(UInt8(topicBytes.count))
    data.append(UInt8(eventBytes.count))
    data.append(contentsOf: joinRefBytes)
    data.append(contentsOf: refBytes)
    data.append(contentsOf: topicBytes)
    data.append(contentsOf: eventBytes)
    data.append(payload)
    return data
  }

  private static func binaryReply(from data: Data) throws -> PhoenixReply {
    let bytes = [UInt8](data)
    guard bytes.count >= 5 else {
      throw PhoenixError.protocolViolation("Binary reply frame too short")
    }
    guard bytes[0] == 1 else {
      throw PhoenixError.protocolViolation("Unsupported binary frame kind")
    }

    let joinRefLen = Int(bytes[1])
    let refLen = Int(bytes[2])
    let topicLen = Int(bytes[3])
    let statusLen = Int(bytes[4])
    let headerLen = 5
    let required = headerLen + joinRefLen + refLen + topicLen + statusLen
    guard bytes.count >= required else {
      throw PhoenixError.protocolViolation("Binary reply frame malformed lengths")
    }

    var offset = headerLen
    let joinRef = String(decoding: bytes[offset..<(offset + joinRefLen)], as: UTF8.self)
    offset += joinRefLen
    let ref = String(decoding: bytes[offset..<(offset + refLen)], as: UTF8.self)
    offset += refLen
    let topic = String(decoding: bytes[offset..<(offset + topicLen)], as: UTF8.self)
    offset += topicLen
    let rawStatus = String(decoding: bytes[offset..<(offset + statusLen)], as: UTF8.self)

    guard let status = PushStatus(rawValue: rawStatus) else {
      throw PhoenixError.protocolViolation("Binary reply status is invalid")
    }

    return PhoenixReply(
      ref: ref,
      joinRef: joinRef.isEmpty ? nil : joinRef,
      topic: Topic(topic),
      status: status,
      binaryResponse: Data(bytes[required...])
    )
  }

  private static func binaryFrameKind(from data: Data) throws -> UInt8 {
    guard let kind = data.first else {
      throw PhoenixError.protocolViolation("Binary frame too short")
    }
    return kind
  }

  private static func binaryMessage(from data: Data) throws -> PhoenixBinaryMessage? {
    let bytes = [UInt8](data)
    guard bytes.count >= 1 else {
      throw PhoenixError.protocolViolation("Binary frame too short")
    }

    switch bytes[0] {
    case 0:
      guard bytes.count >= 4 else {
        throw PhoenixError.protocolViolation("Binary push frame too short")
      }
      let joinRefLen = Int(bytes[1])
      let topicLen = Int(bytes[2])
      let eventLen = Int(bytes[3])
      let headerLen = 4
      let required = headerLen + joinRefLen + topicLen + eventLen
      guard bytes.count >= required else {
        throw PhoenixError.protocolViolation("Binary push frame malformed lengths")
      }

      var offset = headerLen
      let joinRef = String(decoding: bytes[offset..<(offset + joinRefLen)], as: UTF8.self)
      offset += joinRefLen
      let topic = String(decoding: bytes[offset..<(offset + topicLen)], as: UTF8.self)
      offset += topicLen
      let event = String(decoding: bytes[offset..<(offset + eventLen)], as: UTF8.self)
      offset += eventLen
      let payload = Data(bytes[offset...])

      return PhoenixBinaryMessage(
        ref: nil,
        joinRef: joinRef.isEmpty ? nil : joinRef,
        topic: Topic(topic),
        event: PhoenixEvent(rawValue: event),
        payload: payload
      )

    case 1:
      return nil

    case 2:
      guard bytes.count >= 3 else {
        throw PhoenixError.protocolViolation("Binary broadcast frame too short")
      }
      let topicLen = Int(bytes[1])
      let eventLen = Int(bytes[2])
      let headerLen = 3
      let required = headerLen + topicLen + eventLen
      guard bytes.count >= required else {
        throw PhoenixError.protocolViolation("Binary broadcast frame malformed lengths")
      }

      var offset = headerLen
      let topic = String(decoding: bytes[offset..<(offset + topicLen)], as: UTF8.self)
      offset += topicLen
      let event = String(decoding: bytes[offset..<(offset + eventLen)], as: UTF8.self)
      offset += eventLen
      let payload = Data(bytes[offset...])

      return PhoenixBinaryMessage(
        ref: nil,
        joinRef: nil,
        topic: Topic(topic),
        event: PhoenixEvent(rawValue: event),
        payload: payload
      )

    default:
      throw PhoenixError.protocolViolation("Unsupported binary frame kind")
    }
  }

  private func messages(
    rawTopic: String,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy
  ) async -> AsyncStream<PhoenixMessage> {
    let (stream, _) = await makeMessagesStream(rawTopic: rawTopic, bufferingPolicy: bufferingPolicy)
    return stream
  }

  func makeMessagesStream(
    topic: Topic,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> (stream: AsyncStream<PhoenixMessage>, cancel: @Sendable () -> Void) {
    await makeMessagesStream(rawTopic: topic.rawValue, bufferingPolicy: bufferingPolicy)
  }

  private func makeMessagesStream(
    rawTopic: String,
    bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy
  ) async -> (stream: AsyncStream<PhoenixMessage>, cancel: @Sendable () -> Void) {
    let id = UUID()
    let (stream, continuation) = AsyncStream<PhoenixMessage>.makeStream(bufferingPolicy: bufferingPolicy)
    await topicHub.register(topic: rawTopic, continuation: continuation, id: id)

    let unregister: @Sendable () -> Void = {
      Task { [weak self] in
        await self?.topicHub.unregister(topic: rawTopic, id: id)
      }
    }

    let cancel: @Sendable () -> Void = {
      continuation.finish()
      unregister()
    }

    continuation.onTermination = { _ in
      unregister()
    }

    return (stream, cancel)
  }

  func binaryMessages(
    topic: Topic,
    bufferingPolicy: AsyncStream<PhoenixBinaryMessage>.Continuation.BufferingPolicy = .unbounded
  ) async -> AsyncStream<PhoenixBinaryMessage> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<PhoenixBinaryMessage>.makeStream(bufferingPolicy: bufferingPolicy)
    await binaryTopicHub.register(topic: topic.rawValue, continuation: continuation, id: id)
    continuation.onTermination = { _ in
      Task { [weak self] in
        await self?.binaryTopicHub.unregister(topic: topic.rawValue, id: id)
      }
    }
    return stream
  }

  private func setState(_ newState: ConnectionState) async {
    await stateHub.set(newState)
    emitMetric(.connectionStateChanged(newState))
  }

  private func emitTopic(_ message: PhoenixMessage) async {
    await topicHub.emit(topic: message.topic.rawValue, message)
  }

  private func emitBinaryTopic(_ message: PhoenixBinaryMessage) async {
    await binaryTopicHub.emit(topic: message.topic.rawValue, message)
  }

  private func setPendingHeartbeatRef(_ ref: String?) {
    pendingHeartbeatRef = ref
  }

  private func hasPendingHeartbeatRef() -> Bool {
    pendingHeartbeatRef != nil
  }

  private func clearPendingHeartbeatAndDisconnect() async {
    pendingHeartbeatRef = nil
    guard let transport else { return }

    await handleTerminalTransportFailure(
      state: .disconnected(code: 1000, reason: "heartbeat timeout"),
      trigger: .error("heartbeat timeout")
    )
    await transport.disconnect(code: 1000, reason: "heartbeat timeout")
  }

  private func emitMetric(_ event: ClientMetricEvent) {
    metricsHook?(event)
  }

  private func shouldEmitTextMessage(_ message: PhoenixMessage) -> Bool {
    shouldEmitMessage(topic: message.topic, joinRef: message.joinRef, event: message.event)
  }

  private func shouldEmitBinaryMessage(_ message: PhoenixBinaryMessage) -> Bool {
    shouldEmitMessage(topic: message.topic, joinRef: message.joinRef, event: message.event)
  }

  private func shouldEmitMessage(topic: Topic, joinRef: String?, event: PhoenixEvent) -> Bool {
    guard let joinRef else { return true }

    let currentJoinRef = channelJoinRefs[topic.rawValue]
    guard currentJoinRef == joinRef else {
      log(
        .debug,
        category: "channel",
        message: "stale message dropped",
        metadata: [
          "topic": topic.rawValue,
          "event": event.rawValue,
          "joinRef": joinRef,
          "currentJoinRef": currentJoinRef ?? ""
        ]
      )
      return false
    }

    return true
  }

  private func logTransportEvent(_ event: TransportEvent) {
    switch event {
    case .open:
      log(.info, category: "transport", message: "socket opened")
    case .close(let code, let reason):
      log(
        .info,
        category: "transport",
        message: "socket closed",
        metadata: ["code": String(code), "reason": reason ?? ""]
      )
    case .error(let error):
      log(.error, category: "transport", message: "socket error", metadata: ["error": error])
    case .message:
      break
    case .messageData:
      break
    }
  }

  private func log(
    _ level: OSLogType,
    category: String,
    message: String,
    metadata: [String: String] = [:]
  ) {
    logSink?(level, category, message, metadata)

    guard let logger else { return }
    let metadataString = metadata
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    let composed = metadataString.isEmpty ? "\(category): \(message)" : "\(category): \(message) \(metadataString)"

    switch level {
    case .debug:
#if canImport(OSLog)
      logger.debug("\(composed, privacy: .public)")
#else
      logger.debug(composed)
#endif
    case .info:
#if canImport(OSLog)
      logger.info("\(composed, privacy: .public)")
#else
      logger.info(composed)
#endif
    case .error, .fault:
#if canImport(OSLog)
      logger.error("\(composed, privacy: .public)")
#else
      logger.error(composed)
#endif
    default:
#if canImport(OSLog)
      logger.notice("\(composed, privacy: .public)")
#else
      logger.notice(composed)
#endif
    }
  }
}
