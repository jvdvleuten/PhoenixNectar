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

public struct TransportFailure: Error, Sendable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

extension TransportFailure: LocalizedError {
  public var errorDescription: String? { message }
}

public enum TransportEvent: Sendable {
  case open
  case error(TransportFailure)
  case message(String)
  case close(Int, String?)
}

//----------------------------------------------------------------------
// MARK: - Transport Protocol
//----------------------------------------------------------------------
/**
 Defines a `Socket`'s Transport layer.
 */
// sourcery: AutoMockable
public protocol PhoenixTransport {

  /// The current `ReadyState` of the `Transport` layer
  var readyState: PhoenixTransportReadyState { get }

  /// Async event stream emitted by the transport.
  func events(
    bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy
  ) -> AsyncStream<TransportEvent>

  /**
   Connect to the server

   - Parameters:
   - headers: Headers to include in the URLRequests when opening the Websocket connection. Can be empty [:]
   */
  func connect(with headers: [String: String])

  /**
   Disconnect from the server.

   - Parameters:
   - code: Status code as defined by <ahref="http://tools.ietf.org/html/rfc6455#section-7.4">Section 7.4 of RFC 6455</a>.
   - reason: Reason why the connection is closing. Optional.
   */
  func disconnect(code: Int, reason: String?)

  /**
   Sends a message to the server.

   - Parameter data: Data to send.
   */
  func send(data: Data)
}

//----------------------------------------------------------------------
// MARK: - Transport Ready State Enum
//----------------------------------------------------------------------
/**
 Available `ReadyState`s of a `Transport` layer.
 */
public enum PhoenixTransportReadyState: Sendable {

  /// The `Transport` is opening a connection to the server.
  case connecting

  /// The `Transport` is connected to the server.
  case open

  /// The `Transport` is closing the connection to the server.
  case closing

  /// The `Transport` has disconnected from the server.
  case closed
}

actor TransportEventBroadcaster {
  private var continuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]

  func add(_ continuation: AsyncStream<TransportEvent>.Continuation, id: UUID) {
    continuations[id] = continuation
  }

  func yield(_ event: TransportEvent) {
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  func finish() {
    for continuation in continuations.values {
      continuation.finish()
    }
    continuations.removeAll()
  }

  func remove(_ id: UUID) {
    continuations[id] = nil
  }
}

//----------------------------------------------------------------------
// MARK: - Default Websocket Transport Implementation
//----------------------------------------------------------------------
/**
 A `Transport` implementation that relies on URLSession's native WebSocket
 implementation.

 This implementation ships default with SwiftPhoenixClient however
 SwiftPhoenixClient supports earlier OS versions using one of the submodule
 `Transport` implementations. Or you can create your own implementation using
 your own WebSocket library or implementation.
 */
@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
public final class URLSessionTransport: NSObject, PhoenixTransport, URLSessionWebSocketDelegate, @unchecked Sendable {

  /// The URL to connect to
  internal let url: URL

  /// The URLSession configuration
  internal let configuration: URLSessionConfiguration

  /// The underling URLSession. Assigned during `connect()`
  private var session: URLSession? = nil

  /// The ongoing task. Assigned during `connect()`
  private var task: URLSessionWebSocketTask? = nil

  /// Holds the current receive task
  private var receiveMessageTask: Task<Void, Never>? {
      didSet {
          oldValue?.cancel()
      }
  }

  private let broadcaster = TransportEventBroadcaster()

  /**
   Initializes a `Transport` layer built using URLSession's WebSocket

   Example:

   ```swift
   let url = URL("wss://example.com/socket")
   let transport: Transport = URLSessionTransport(url: url)
   ```

   Using a custom `URLSessionConfiguration`

   ```swift
   let url = URL("wss://example.com/socket")
   let configuration = URLSessionConfiguration.default
   let transport: Transport = URLSessionTransport(url: url, configuration: configuration)
   ```

   - parameter url: URL to connect to
   - parameter configuration: Provide your own URLSessionConfiguration. Uses `.default` if none provided
   */
  public init(url: URL, configuration: URLSessionConfiguration = .default) {

    // URLSession requires that the endpoint be "wss" instead of "https".
    let endpoint = url.absoluteString
    let wsEndpoint = endpoint
      .replacingOccurrences(of: "http://", with: "ws://")
      .replacingOccurrences(of: "https://", with: "wss://")

    // Force unwrapping should be safe here since a valid URL came in and we just
    // replaced the protocol.
    self.url = URL(string: wsEndpoint)!
    self.configuration = configuration

    super.init()
  }

  deinit {
    receiveMessageTask?.cancel()
    let broadcaster = self.broadcaster
    Task {
      await broadcaster.finish()
    }
  }


  // MARK: - Transport
  public var readyState: PhoenixTransportReadyState = .closed

  public func events(
    bufferingPolicy: AsyncStream<TransportEvent>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<TransportEvent> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      let id = UUID()
      Task { await self.broadcaster.add(continuation, id: id) }
      continuation.onTermination = { _ in
        Task { await self.broadcaster.remove(id) }
      }
    }
  }

  public func connect(with headers: [String: String]) {
    self.readyState = .connecting

    // Create the session and websocket task
    self.session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: nil)
    var request = URLRequest(url: url)

    headers.forEach { (key: String, value: String) in
        request.addValue(value, forHTTPHeaderField: key)
    }

    self.task = self.session?.webSocketTask(with: request)
    self.task?.resume()
  }

  public func disconnect(code: Int, reason: String?) {
    /*
     TODO:
     1. Provide a "strict" mode that fails if an invalid close code is given
     2. If strict mode is disabled, default to CloseCode.invalid
     3. Provide default .normalClosure function
     */
    let closeCode = URLSessionWebSocketTask.CloseCode.init(rawValue: code) ?? .normalClosure

    self.readyState = .closing
    self.task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
    self.session?.finishTasksAndInvalidate()
    receiveMessageTask?.cancel()
  }

  public func send(data: Data) {
    guard let text = String(data: data, encoding: .utf8) else { return }
    let task = self.task
    guard let task else { return }

    Task { [weak self] in
      do {
        try await task.send(.string(text))
      } catch {
        guard let self else { return }
        self.abnormalErrorReceived(error)
      }
    }
  }


  // MARK: - URLSessionWebSocketDelegate
  public func urlSession(_ session: URLSession,
                       webSocketTask: URLSessionWebSocketTask,
                       didOpenWithProtocol protocol: String?) {
    self.readyState = .open
    Task {
      await self.broadcaster.yield(.open)
    }

    // Start receiving messages
    self.receive()
  }

  public func urlSession(_ session: URLSession,
                       webSocketTask: URLSessionWebSocketTask,
                       didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                       reason: Data?) {
    self.readyState = .closed
    Task {
      await self.broadcaster.yield(.close(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) }))
    }
  }

  public func urlSession(_ session: URLSession,
                       task: URLSessionTask,
                       didCompleteWithError error: Error?) {
    // The task has terminated. Inform the delegate that the transport has closed abnormally
    // if this was caused by an error.
    guard let err = error else { return }

    self.abnormalErrorReceived(err)
  }


  // MARK: - Private
  private func receive() {
    let task = self.task
    guard let task else { return }

    let receiveTask = Task { [weak self] in
      guard let self else { return }

      while !Task.isCancelled {
        do {
          let message = try await task.receive()
          switch message {
          case .data:
            break
          case .string(let text):
            await self.broadcaster.yield(.message(text))
          @unknown default:
            break
          }
        } catch {
          guard !Task.isCancelled else { return }
          self.abnormalErrorReceived(error)
          return
        }
      }
    }

    receiveMessageTask = receiveTask
  }

  private func abnormalErrorReceived(_ error: Error) {
    self.readyState = .closed

    Task {
      await self.broadcaster.yield(.error(TransportFailure(message: error.localizedDescription)))
      await self.broadcaster.yield(.close(Socket.CloseCode.abnormal.rawValue, error.localizedDescription))
    }
  }
}
