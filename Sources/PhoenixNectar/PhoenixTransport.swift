import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TransportEvent: Sendable {
  case open
  case error(String)
  case message(String)
  case close(Int, String?)
}

public protocol PhoenixTransport: AnyObject {
  var readyState: PhoenixTransportReadyState { get }
  func events(bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy) -> AsyncStream<TransportEvent>
  func connect(with headers: [String: String])
  func disconnect(code: Int, reason: String?)
  func send(data: Data)
}

public enum PhoenixTransportReadyState: Sendable {
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
public final class URLSessionTransport: NSObject, PhoenixTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
  internal let url: URL
  internal let configuration: URLSessionConfiguration

  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>? {
    didSet { oldValue?.cancel() }
  }

  private let broadcaster = TransportEventBroadcaster()

  public init(url: URL, configuration: URLSessionConfiguration = .default) {
    let endpoint = url.absoluteString
    let wsEndpoint = endpoint
      .replacingOccurrences(of: "http://", with: "ws://")
      .replacingOccurrences(of: "https://", with: "wss://")
    self.url = URL(string: wsEndpoint)!
    self.configuration = configuration
    super.init()
  }

  deinit {
    receiveTask?.cancel()
    let broadcaster = self.broadcaster
    Task { await broadcaster.finish() }
  }

  public var readyState: PhoenixTransportReadyState = .closed

  public func events(bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<TransportEvent> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      let id = UUID()
      Task { await self.broadcaster.add(continuation, id: id) }
      continuation.onTermination = { _ in
        Task { await self.broadcaster.remove(id) }
      }
    }
  }

  public func connect(with headers: [String: String]) {
    readyState = .connecting
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    var request = URLRequest(url: url)
    headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
    task = session?.webSocketTask(with: request)
    task?.resume()
  }

  public func disconnect(code: Int, reason: String?) {
    readyState = .closing
    let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
    task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
    session?.finishTasksAndInvalidate()
    receiveTask?.cancel()
  }

  public func send(data: Data) {
    guard let text = String(data: data, encoding: .utf8), let task else { return }
    Task { [weak self] in
      do {
        try await task.send(.string(text))
      } catch {
        self?.abnormal(error)
      }
    }
  }

  public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    readyState = .open
    Task { await broadcaster.yield(.open) }
    receiveLoop()
  }

  public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    readyState = .closed
    Task { await broadcaster.yield(.close(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) })) }
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    abnormal(error)
  }

  private func receiveLoop() {
    guard let task else { return }
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          let message = try await task.receive()
          if case .string(let text) = message {
            await self.broadcaster.yield(.message(text))
          }
        } catch {
          guard !Task.isCancelled else { return }
          self.abnormal(error)
          return
        }
      }
    }
  }

  private func abnormal(_ error: Error) {
    readyState = .closed
    Task {
      await broadcaster.yield(.error(error.localizedDescription))
      await broadcaster.yield(.close(999, error.localizedDescription))
    }
  }
}
