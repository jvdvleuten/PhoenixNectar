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


/// Represnts pushing data to a `Channel` through the `Socket`
@MainActor
public class Push {
  
  /// The channel sending the Push
  public weak var channel: Channel?
  
  /// The event, for example `phx_join`
  public let event: String
  
  /// The payload, for example ["user_id": "abc123"]
  public var payload: Payload
  
  /// The push timeout. Default is 10.0 seconds
  public var timeout: TimeInterval
  
  /// The server's response to the Push
  var receivedMessage: Message?
  
  /// Scheduler for push timeout
  private let scheduler: any PhoenixScheduler

  /// One-shot schedule token for timeout
  private var timeoutSchedule: PhoenixSchedulerToken?
  
  /// Hooks into a Push. Where .receive("ok", callback(Payload)) are stored
  var receiveHooks: [String: [(Message) -> Void]]
  
  /// True if the Push has been sent
  var sent: Bool
  
  /// The reference ID of the Push
  var ref: String?
  
  /// The event that is associated with the reference ID of the Push
  var refEvent: String?
  
  
  
  /// Initializes a Push
  ///
  /// - parameter channel: The Channel
  /// - parameter event: The event, for example ChannelEvent.join
  /// - parameter payload: Optional. The Payload to send, e.g. ["user_id": "abc123"]
  /// - parameter timeout: Optional. The push timeout. Default is 10.0s
  init(channel: Channel,
       event: String,
       payload: Payload = [:],
       timeout: TimeInterval = Defaults.timeoutInterval) {
    self.channel = channel
    self.event = event
    self.payload = payload
    self.timeout = timeout
    self.receivedMessage = nil
    self.receiveHooks = [:]
    self.sent = false
    self.ref = nil
    self.scheduler = channel.scheduler
  }
  
  
  
  /// Resets and sends the Push
  /// - parameter timeout: Optional. The push timeout. Default is 10.0s
  public func resend(_ timeout: TimeInterval = Defaults.timeoutInterval) {
    self.timeout = timeout
    self.reset()
    self.send()
  }
  
  /// Sends the Push. If it has already timed out, then the call will
  /// be ignored and return early. Use `resend` in this case.
  public func send() {
    guard !hasReceived(status: "timeout") else { return }
    
    self.startTimeout()
    self.sent = true
    self.channel?.socket?.push(
      topic: channel?.topic ?? "",
      event: self.event,
      payload: self.payload,
      ref: self.ref,
      joinRef: channel?.joinRef
    )
  }
  
  /// Receive a specific event when sending an outbound message. This callback
  /// does not manage retain cycles for you, so capture weak references as needed.
  ///
  /// Example:
  ///
  ///     channel
  ///         .send(event:"custom", payload: ["body": "example"])
  ///         .receive("error") { [weak self] payload in
  ///             print("Error: ", payload)
  ///         }
  ///
  /// - parameter status: Status to receive
  /// - parameter callback: Callback to fire when the status is recevied
  @discardableResult
  public func receive(_ status: String,
                      callback: @escaping ((Message) -> ())) -> Push {
    // If the message has already been received, pass it to the callback immediately
    if hasReceived(status: status), let receivedMessage = self.receivedMessage {
      callback(receivedMessage)
    }
    
    if receiveHooks[status] == nil {
      /// Create a new array of hooks if no previous hook is associated with status
      receiveHooks[status] = [callback]
    } else {
      /// A previous hook for this status already exists. Just append the new hook
      receiveHooks[status]?.append(callback)
    }
    
    return self
  }

  @discardableResult
  public func receive(_ status: PushStatus,
                      callback: @escaping ((Message) -> ())) -> Push {
    self.receive(status.rawValue, callback: callback)
  }
  
  
  
  /// Resets the Push as it was after it was first tnitialized.
  internal func reset() {
    self.cancelRefEvent()
    self.ref = nil
    self.refEvent = nil
    self.receivedMessage = nil
    self.sent = false
  }
  
  
  /// Finds the receiveHook which needs to be informed of a status response
  ///
  /// - parameter status: Status which was received, e.g. "ok", "error", "timeout"
  /// - parameter response: Response that was received
  private func matchReceive(_ status: String, message: Message) {
    receiveHooks[status]?.forEach( { $0(message) } )
  }
  
  /// Reverses the result on channel.on(ChannelEvent, callback) that spawned the Push
  private func cancelRefEvent() {
    guard let refEvent = self.refEvent else { return }
    self.channel?.off(refEvent)
  }
  
  /// Cancel any ongoing Timeout Timer
  internal func cancelTimeout() {
    self.scheduler.cancel(self.timeoutSchedule)
    self.timeoutSchedule = nil
  }
  
  /// Starts the Timer which will trigger a timeout after a specific _timeout_
  /// time, in milliseconds, is reached.
  internal func startTimeout() {
    // Cancel any existing timeout before starting a new one
    self.cancelTimeout()
    
    guard
      let channel = channel,
      let socket = channel.socket else { return }
    
    let ref = socket.makeRef()
    let refEvent = channel.replyEventName(ref)
    
    self.ref = ref
    self.refEvent = refEvent
    
    /// If a response is received  before the Timer triggers, cancel timer
    /// and match the recevied event to it's corresponding hook
    channel.on(refEvent) { [weak self] message in
      guard let self else { return }
      self.cancelRefEvent()
      self.cancelTimeout()
      self.receivedMessage = message
      
      /// Check if there is event a status available
      guard let status = message.status else { return }
      self.matchReceive(status, message: message)
    }
    
    /// Setup and start the Timeout timer.
    self.timeoutSchedule = self.scheduler.scheduleOnce(after: timeout, tolerance: nil) { [weak self] in
      self?.trigger("timeout", payload: [:])
    }
  }
  
  /// Checks if a status has already been received by the Push.
  ///
  /// - parameter status: Status to check
  /// - return: True if given status has been received by the Push.
  internal func hasReceived(status: String) -> Bool {
    return self.receivedMessage?.status == status
  }

  internal func hasReceived(status: PushStatus) -> Bool {
    self.hasReceived(status: status.rawValue)
  }
  
  /// Triggers an event to be sent though the Channel
  internal func trigger(_ status: String, payload: Payload) {
    /// If there is no ref event, then there is nothing to trigger on the channel
    guard let refEvent = self.refEvent else { return }
    
    var mutPayload = payload
    mutPayload["status"] = .string(status)
    
    self.channel?.trigger(event: refEvent, payload: mutPayload)
  }

  internal func trigger(_ status: PushStatus, payload: Payload) {
    self.trigger(status.rawValue, payload: payload)
  }
}

private actor PushAsyncContinuationState {
  private var continuation: CheckedContinuation<Message, Error>?

  func install(_ continuation: CheckedContinuation<Message, Error>) {
    self.continuation = continuation
  }

  func resolve(_ result: Result<Message, Error>) {
    guard let continuation else {
      return
    }
    self.continuation = nil

    switch result {
    case .success(let message):
      continuation.resume(returning: message)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }
}

public enum PushAsyncError: Error {
  case timeout
  case serverError(Message)
}

extension Push {
  /// Waits for an "ok", "error", or "timeout" response to this push.
  public func responseAsync() async throws -> Message {
    let state = PushAsyncContinuationState()

    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        Task { await state.install(continuation) }

        self.receive(.ok) { message in
          Task { await state.resolve(.success(message)) }
        }
        self.receive(.error) { message in
          Task { await state.resolve(.failure(PushAsyncError.serverError(message))) }
        }
        self.receive(.timeout) { _ in
          Task { await state.resolve(.failure(PushAsyncError.timeout)) }
        }
      }
    }, onCancel: {
      Task { await state.resolve(.failure(CancellationError())) }
    })
  }
}
