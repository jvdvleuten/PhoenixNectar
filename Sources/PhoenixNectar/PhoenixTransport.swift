import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TransportEvent: Sendable, Equatable {
  case open
  case error(String)
  case message(String)
  case messageData(Data)
  case close(Int, String?)
}

protocol PhoenixTransport: Sendable {
  func readyState() async -> PhoenixTransportReadyState
  func events(bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy) async -> AsyncStream<TransportEvent>
  func connect(with headers: [String: String]) async
  func disconnect(code: Int, reason: String?) async
  func sendText(data: Data) async
  func sendBinary(data: Data) async
}

enum PhoenixTransportReadyState: Sendable {
  case connecting
  case open
  case closing
  case closed
}

actor TransportEventBroadcaster {
  private var continuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]

  func add(_ continuation: AsyncStream<TransportEvent>.Continuation, id: UUID) {
    continuations[id] = continuation
  }

  func remove(_ id: UUID) {
    continuations[id] = nil
  }

  func yield(_ event: TransportEvent) {
    continuations.values.forEach { $0.yield(event) }
  }

  func finish() {
    continuations.values.forEach { $0.finish() }
    continuations.removeAll()
  }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
private final class URLSessionWebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate {
  private let onOpen: @Sendable () async -> Void
  private let onClose: @Sendable (Int, String?) async -> Void
  private let onComplete: @Sendable (Error) async -> Void

  init(
    onOpen: @escaping @Sendable () async -> Void,
    onClose: @escaping @Sendable (Int, String?) async -> Void,
    onComplete: @escaping @Sendable (Error) async -> Void
  ) {
    self.onOpen = onOpen
    self.onClose = onClose
    self.onComplete = onComplete
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    Task { await onOpen() }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    Task {
      await onClose(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) })
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    Task { await onComplete(error) }
  }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
actor URLSessionTransport: PhoenixTransport {
  internal let url: URL
  internal let configuration: URLSessionConfiguration

  private let broadcaster = TransportEventBroadcaster()
  private var ready: PhoenixTransportReadyState = .closed
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var delegateProxy: URLSessionWebSocketDelegateProxy?

  init(url: URL, configuration: URLSessionConfiguration = .default) {
    let endpoint = url.absoluteString
    let wsEndpoint = endpoint
      .replacingOccurrences(of: "http://", with: "ws://")
      .replacingOccurrences(of: "https://", with: "wss://")
    self.url = URL(string: wsEndpoint) ?? url
    self.configuration = configuration
  }

  func readyState() async -> PhoenixTransportReadyState {
    ready
  }

  func events(bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy = .unbounded) async -> AsyncStream<TransportEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: bufferingPolicy)
    await broadcaster.add(continuation, id: id)
    continuation.onTermination = { _ in
      Task { [weak self] in
        await self?.broadcaster.remove(id)
      }
    }
    return stream
  }

  func connect(with headers: [String: String]) async {
    // Clean up any previous connection to avoid leaking a URLSession.
    receiveTask?.cancel()
    receiveTask = nil
    task?.cancel(with: .normalClosure, reason: nil)
    session?.finishTasksAndInvalidate()
    task = nil
    session = nil
    delegateProxy = nil

    ready = .connecting

    let proxy = URLSessionWebSocketDelegateProxy(
      onOpen: { [weak self] in await self?.didOpen() },
      onClose: { [weak self] code, reason in await self?.didClose(code: code, reason: reason) },
      onComplete: { [weak self] error in await self?.didComplete(error: error) }
    )
    delegateProxy = proxy

    var request = URLRequest(url: url)
    headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

    let session = URLSession(configuration: configuration, delegate: proxy, delegateQueue: nil)
    let webSocketTask = session.webSocketTask(with: request)

    self.session = session
    self.task = webSocketTask
    webSocketTask.resume()
  }

  func disconnect(code: Int, reason: String?) async {
    ready = .closing

    let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
    task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
    session?.finishTasksAndInvalidate()

    receiveTask?.cancel()
    receiveTask = nil
    task = nil
    session = nil
    delegateProxy = nil
    ready = .closed
    await broadcaster.yield(.close(code, reason))
    await broadcaster.finish()
  }

  func sendText(data: Data) async {
    guard let task,
          let text = String(data: data, encoding: .utf8)
    else {
      return
    }

    do {
      try await task.send(.string(text))
    } catch {
      await abnormal(error)
    }
  }

  func sendBinary(data: Data) async {
    guard let task else { return }
    do {
      try await task.send(.data(data))
    } catch {
      await abnormal(error)
    }
  }

  fileprivate func didOpen() async {
    ready = .open
    await broadcaster.yield(.open)
    startReceiveLoop()
  }

  fileprivate func didClose(code: Int, reason: String?) async {
    ready = .closed
    receiveTask?.cancel()
    receiveTask = nil
    await broadcaster.yield(.close(code, reason))
    await broadcaster.finish()
  }

  fileprivate func didComplete(error: Error) async {
    await abnormal(error)
  }

  private func startReceiveLoop() {
    receiveTask?.cancel()

    receiveTask = Task { [weak self] in
      guard let self else { return }

      while !Task.isCancelled {
        do {
          guard let socketTask = await self.task else { return }
          let message = try await socketTask.receive()

          if case .string(let text) = message {
            await self.broadcaster.yield(.message(text))
          } else if case .data(let data) = message {
            await self.broadcaster.yield(.messageData(data))
          }
        } catch {
          guard !Task.isCancelled else { return }
          await self.abnormal(error)
          return
        }
      }
    }
  }

  private func abnormal(_ error: Error) async {
    ready = .closed
    receiveTask?.cancel()
    receiveTask = nil
    task = nil
    session = nil
    delegateProxy = nil
    await broadcaster.yield(.error(error.localizedDescription))
    await broadcaster.finish()
  }
}
