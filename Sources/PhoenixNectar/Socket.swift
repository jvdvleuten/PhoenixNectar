// Copyright (c) 2021 David Stump <david@davidstump.net>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SocketError: Error {
  case abnormalClosureError
  case malformedEndpoint(String)
  case malformedEndpointComponents(String)
  case encodeFailure(Error)
  case decodeFailure(Error)
}

/// Struct that gathers callbacks assigned to the Socket
final class StateChangeCallbacks {
  var open: [(ref: String, callback: () -> Void)] = []
  var close: [(ref: String, callback: (Int, String?) -> Void)] = []
  var error: [(ref: String, callback: (Error) -> Void)] = []
  var message: [(ref: String, callback: (Message) -> Void)] = []
}

@MainActor
public final class Socket {
  public let endPoint: String
  public private(set) var endPointUrl: URL
  public let paramsClosure: PayloadClosure?

  private let transport: (URL) -> any PhoenixTransport
  private let runtime = SocketRuntime()

  public let vsn: String
  public var encode: (SocketFrame) throws -> Data = Defaults.encodeFrame
  public var decode: (Data) throws -> SocketFrame = Defaults.decodeFrame
  public var timeout: TimeInterval = Defaults.timeoutInterval
  public var headers: [String: String] = [:]
  public var heartbeatInterval: TimeInterval = Defaults.heartbeatInterval
  public var heartbeatTolerance: Duration = Defaults.heartbeatTolerance
  public var reconnectAfter: @Sendable (Int) -> TimeInterval = Defaults.reconnectSteppedBackOff
  public var rejoinAfter: @Sendable (Int) -> TimeInterval = Defaults.rejoinSteppedBackOff
  public var logger: (any PhoenixLogger)?
  public var skipHeartbeat: Bool = false
  public var disableSSLCertValidation: Bool = false

  #if os(Linux)
  #else
  public var enabledSSLCipherSuites: [SSLCipherSuite]?
  #endif

  let stateChangeCallbacks: StateChangeCallbacks = StateChangeCallbacks()
  public var channels: [Channel] { _channels }
  private var _channels: [Channel] = []

  var ref: UInt64 = UInt64.min

  let scheduler: any PhoenixScheduler
  private var heartbeatSchedule: PhoenixSchedulerToken?
  private var reconnectSchedule: PhoenixSchedulerToken?

  var closeStatus: CloseStatus = .unknown
  var connection: PhoenixTransport? = nil
  private var connectionEventsTask: Task<Void, Never>? = nil

  public var params: Payload? { self.paramsClosure?() }

  @available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
  public convenience init(_ endPoint: String,
                          params: Payload? = nil,
                          vsn: String = Defaults.vsn,
                          scheduler: (any PhoenixScheduler)? = nil) throws {
    try self.init(endPoint: endPoint,
                  transport: { url in URLSessionTransport(url: url) },
                  paramsClosure: { params },
                  vsn: vsn,
                  scheduler: scheduler ?? ClockScheduler())
  }

  @available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
  public convenience init(_ endPoint: String,
                          paramsClosure: PayloadClosure?,
                          vsn: String = Defaults.vsn,
                          scheduler: (any PhoenixScheduler)? = nil) throws {
    try self.init(endPoint: endPoint,
                  transport: { url in URLSessionTransport(url: url) },
                  paramsClosure: paramsClosure,
                  vsn: vsn,
                  scheduler: scheduler ?? ClockScheduler())
  }

  public init(endPoint: String,
              transport: @escaping ((URL) -> PhoenixTransport),
              paramsClosure: PayloadClosure? = nil,
              vsn: String = Defaults.vsn,
              scheduler: (any PhoenixScheduler)? = nil) throws {
    self.transport = transport
    self.paramsClosure = paramsClosure
    self.endPoint = endPoint
    self.vsn = vsn
    self.scheduler = scheduler ?? ClockScheduler()
    self.endPointUrl = try Socket.buildEndpointUrl(endpoint: endPoint,
                                                   paramsClosure: paramsClosure,
                                                   vsn: vsn)
  }

  public var websocketProtocol: String {
    switch endPointUrl.scheme {
    case "https": return "wss"
    case "http": return "ws"
    default: return endPointUrl.scheme ?? ""
    }
  }

  public var isConnected: Bool { self.connectionState == .open }
  public var isConnecting: Bool { self.connectionState == .connecting }
  public var connectionState: PhoenixTransportReadyState { self.connection?.readyState ?? .closed }

  public func connect() {
    guard !isConnected && !isConnecting else { return }
    self.closeStatus = .unknown

    do {
      self.endPointUrl = try Socket.buildEndpointUrl(endpoint: self.endPoint,
                                                     paramsClosure: self.paramsClosure,
                                                     vsn: vsn)
    } catch {
      self.onConnectionError(error)
      return
    }

    self.connection = self.transport(self.endPointUrl)
    self.consumeConnectionEvents()
    self.connection?.connect(with: self.headers)
  }

  public func disconnect(code: CloseCode = CloseCode.normal,
                         reason: String? = nil,
                         callback: (() -> Void)? = nil) {
    self.closeStatus = CloseStatus(closeCode: code.rawValue)
    Task { await self.resetReconnectSchedule() }
    self.teardown(code: code, reason: reason, callback: callback)
  }

  internal func teardown(code: CloseCode = CloseCode.normal, reason: String? = nil, callback: (() -> Void)? = nil) {
    self.connectionEventsTask?.cancel()
    self.connectionEventsTask = nil
    self.connection?.disconnect(code: code.rawValue, reason: reason)
    self.connection = nil

    self.scheduler.cancel(self.heartbeatSchedule)
    self.heartbeatSchedule = nil

    self.stateChangeCallbacks.close.forEach { $0.callback(code.rawValue, reason) }
    callback?()
  }

  @discardableResult
  public func onOpen(callback: @escaping () -> Void) -> String {
    self.append(callback: callback, to: \.open)
  }

  @discardableResult
  public func onClose(callback: @escaping () -> Void) -> String {
    self.onClose { _, _ in callback() }
  }

  @discardableResult
  public func onClose(callback: @escaping (Int, String?) -> Void) -> String {
    self.append(callback: callback, to: \.close)
  }

  @discardableResult
  public func onError(callback: @escaping (Error) -> Void) -> String {
    self.append(callback: callback, to: \.error)
  }

  @discardableResult
  public func onMessage(callback: @escaping (Message) -> Void) -> String {
    self.append(callback: callback, to: \.message)
  }

  private func append<T>(callback: T, to keyPath: ReferenceWritableKeyPath<StateChangeCallbacks, [(ref: String, callback: T)]>) -> String {
    let ref = makeRef()
    self.stateChangeCallbacks[keyPath: keyPath].append((ref, callback))
    return ref
  }

  public func releaseCallbacks() {
    self.stateChangeCallbacks.open.removeAll()
    self.stateChangeCallbacks.close.removeAll()
    self.stateChangeCallbacks.error.removeAll()
    self.stateChangeCallbacks.message.removeAll()
  }

  public func channel(_ topic: String, params: Payload = [:]) -> Channel {
    let channel = Channel(topic: topic, params: params, socket: self, scheduler: scheduler)
    _channels.append(channel)
    return channel
  }

  public func remove(_ channel: Channel) {
    self.off(channel.stateChangeRefs)
    _channels.removeAll(where: { $0.joinRef == channel.joinRef })
  }

  public func off(_ refs: [String]) {
    self.stateChangeCallbacks.open.removeAll { refs.contains($0.ref) }
    self.stateChangeCallbacks.close.removeAll { refs.contains($0.ref) }
    self.stateChangeCallbacks.error.removeAll { refs.contains($0.ref) }
    self.stateChangeCallbacks.message.removeAll { refs.contains($0.ref) }
  }

  internal func push(topic: String,
                     event: String,
                     payload: Payload,
                     ref: String? = nil,
                     joinRef: String? = nil) {
    let frame = PendingFrame(topic: topic, event: event, payload: payload, ref: ref, joinRef: joinRef)
    if isConnected {
      self.send(frame)
    } else {
      Task { await runtime.enqueueBufferedFrame(frame) }
    }
  }

  public func makeRef() -> String {
    self.ref = (ref == UInt64.max) ? 0 : self.ref + 1
    return String(ref)
  }

  private func onConnectionOpen() async {
    self.log(.info, category: "transport", message: "connected", metadata: ["endpoint": endPoint])
    self.closeStatus = .unknown
    await self.flushSendBuffer()
    await self.resetReconnectSchedule()
    await self.resetHeartbeat()
    self.stateChangeCallbacks.open.forEach { $0.callback() }
  }

  private func onConnectionClosed(code: Int, reason: String?) async {
    self.log(.info, category: "transport", message: "closed", metadata: ["code": String(code), "reason": reason ?? ""])

    self.triggerChannelError()
    self.scheduler.cancel(self.heartbeatSchedule)
    self.heartbeatSchedule = nil

    if self.closeStatus.shouldReconnect {
      await self.scheduleReconnect()
    }

    self.stateChangeCallbacks.close.forEach { $0.callback(code, reason) }
  }

  private func onConnectionError(_ error: Error) {
    self.log(.error, category: "transport", message: error.localizedDescription)
    self.triggerChannelError()
    self.stateChangeCallbacks.error.forEach { $0.callback(error) }
  }

  private func onConnectionMessage(_ rawMessage: String) async {
    guard let data = rawMessage.data(using: .utf8) else {
      self.log(.warning, category: "transport", message: "invalid UTF-8 message")
      return
    }

    let frame: SocketFrame
    do {
      frame = try decode(data)
    } catch {
      self.log(.warning, category: "transport", message: "frame decode failure", metadata: ["error": String(describing: error)])
      return
    }

    let message = Message(frame: frame)
    await runtime.acknowledgeHeartbeat(ref: message.ref)

    _channels.forEach { channel in
      if channel.isMember(message) {
        channel.trigger(message)
      }
    }

    self.stateChangeCallbacks.message.forEach { $0.callback(message) }
  }

  internal func triggerChannelError() {
    _channels.forEach { channel in
      if !(channel.isErrored || channel.isLeaving || channel.isClosed) {
        channel.trigger(event: ChannelEvent.error)
      }
    }
  }

  internal func flushSendBuffer() async {
    guard isConnected else { return }
    let buffered = await runtime.drainBufferedFrames()
    buffered.forEach { self.send($0) }
  }

  internal func removeFromSendBuffer(ref: String) {
    Task { await runtime.removeBufferedFrame(ref: ref) }
  }

  internal static func buildEndpointUrl(endpoint: String, paramsClosure params: PayloadClosure?, vsn: String) throws -> URL {
    guard
      let url = URL(string: endpoint),
      var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw SocketError.malformedEndpoint(endpoint) }

    if !urlComponents.path.contains("/websocket") {
      if urlComponents.path.last != "/" {
        urlComponents.path.append("/")
      }
      urlComponents.path.append("websocket")
    }

    urlComponents.queryItems = [URLQueryItem(name: "vsn", value: vsn)]

    if let params = params?() {
      urlComponents.queryItems?.append(contentsOf: params.map {
        URLQueryItem(name: $0.key, value: $0.value.queryValue)
      })
    }

    guard let qualifiedUrl = urlComponents.url
    else { throw SocketError.malformedEndpointComponents(endpoint) }

    return qualifiedUrl
  }

  internal func leaveOpenTopic(topic: String) {
    guard let dupe = _channels.first(where: { $0.topic == topic && ($0.isJoined || $0.isJoining) })
    else { return }

    self.log(.debug, category: "transport", message: "leaving duplicate topic", metadata: ["topic": topic])
    dupe.leave()
  }

  private func resetHeartbeat() async {
    await runtime.clearPendingHeartbeat()
    self.scheduler.cancel(self.heartbeatSchedule)
    self.heartbeatSchedule = nil

    guard !skipHeartbeat else { return }

    self.heartbeatSchedule = self.scheduler.scheduleRepeating(
      every: heartbeatInterval,
      tolerance: heartbeatTolerance
    ) { [weak self] in
      await self?.sendHeartbeat()
    }
  }

  func sendHeartbeat() async {
    guard isConnected else { return }

    if await runtime.hasPendingHeartbeat() {
      await runtime.clearPendingHeartbeat()
      self.log(.warning, category: "transport", message: "heartbeat timeout; reconnecting")
      self.abnormalClose("heartbeat timeout")
      return
    }

    let nextRef = self.makeRef()
    await runtime.markPendingHeartbeat(nextRef)
    self.push(topic: "phoenix", event: ChannelEvent.heartbeat, payload: [:], ref: nextRef)
  }

  internal func abnormalClose(_ reason: String) {
    self.closeStatus = .abnormal
    self.connection?.disconnect(code: CloseCode.normal.rawValue, reason: reason)
  }

  private func consumeConnectionEvents() {
    self.connectionEventsTask?.cancel()
    guard let connection else { return }

    let stream = connection.events(bufferingPolicy: .unbounded)
    self.connectionEventsTask = Task { [weak self] in
      guard let self else { return }
      for await event in stream {
        await self.handleTransportEvent(event)
      }
    }
  }

  private func handleTransportEvent(_ event: TransportEvent) async {
    switch event {
    case .open:
      await self.onConnectionOpen()
    case .error(let error):
      self.onConnectionError(error)
    case .message(let message):
      await self.onConnectionMessage(message)
    case .close(let code, let reason):
      self.closeStatus.update(transportCloseCode: code)
      await self.onConnectionClosed(code: code, reason: reason)
    }
  }

  private func resetReconnectSchedule() async {
    await runtime.resetReconnectAttempts()
    self.scheduler.cancel(self.reconnectSchedule)
    self.reconnectSchedule = nil
  }

  private func scheduleReconnect() async {
    self.scheduler.cancel(self.reconnectSchedule)

    let attempt = await runtime.nextReconnectAttempt()
    let interval = self.reconnectAfter(attempt)
    self.log(.info, category: "transport", message: "reconnect scheduled", metadata: ["attempt": String(attempt), "in": String(interval)])

    self.reconnectSchedule = self.scheduler.scheduleOnce(after: interval, tolerance: nil) { [weak self] in
      guard let self else { return }
      self.log(.info, category: "transport", message: "attempting reconnect")
      self.teardown(reason: "reconnection") { self.connect() }
    }
  }

  private func log(_ level: LogLevel, category: String, message: String, metadata: [String: String] = [:]) {
    logger?.log(LogEvent(level: level, category: category, message: message, metadata: metadata))
  }

  internal func logDebug(category: String, message: String, metadata: [String: String] = [:]) {
    self.log(.debug, category: category, message: message, metadata: metadata)
  }

  private func send(_ frame: PendingFrame) {
    let encoded: Data
    do {
      encoded = try self.encode(
        SocketFrame(
          joinRef: frame.joinRef,
          ref: frame.ref,
          topic: frame.topic,
          event: frame.event,
          payload: frame.payload
        )
      )
    } catch {
      self.onConnectionError(SocketError.encodeFailure(error))
      return
    }

    self.log(.debug, category: "push", message: "sending frame", metadata: [
      "topic": frame.topic,
      "event": frame.event,
      "ref": frame.ref ?? ""
    ])
    self.connection?.send(data: encoded)
  }
}

extension Socket {
  public func messages(
    bufferingPolicy: AsyncStream<Message>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<Message> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      let ref = self.onMessage { message in
        continuation.yield(message)
      }

      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in
          self.off([ref])
        }
      }
    }
  }
}

extension Socket {
  public enum CloseCode: Int {
    case abnormal = 999
    case normal = 1000
    case goingAway = 1001
  }
}

extension Socket {
  enum CloseStatus {
    case unknown
    case clean
    case abnormal
    case temporary

    init(closeCode: Int) {
      switch closeCode {
      case CloseCode.abnormal.rawValue:
        self = .abnormal
      case CloseCode.goingAway.rawValue:
        self = .temporary
      default:
        self = .clean
      }
    }

    mutating func update(transportCloseCode: Int) {
      switch self {
      case .unknown, .clean, .temporary:
        self = .init(closeCode: transportCloseCode)
      case .abnormal:
        break
      }
    }

    var shouldReconnect: Bool {
      switch self {
      case .unknown, .abnormal:
        return true
      case .clean, .temporary:
        return false
      }
    }
  }
}
