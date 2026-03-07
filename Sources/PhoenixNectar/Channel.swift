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

/// Container class of bindings to the channel
struct Binding {
  
  // The event that the Binding is bound to
  let event: String
  
  // The reference number of the Binding
  let ref: Int
  
  // The callback to be triggered
  let callback: (Message) -> Void
}


///
/// Represents a Channel which is bound to a topic
///
/// A Channel can bind to multiple events on a given topic and
/// be informed when those events occur within a topic.
///
/// ### Example:
///
///     let channel = socket.channel("room:123", params: ["token": "Room Token"])
///     channel.on("new_msg") { payload in print("Got message", payload") }
///     channel.push("new_msg, payload: ["body": "This is a message"])
///         .receive("ok") { payload in print("Sent message", payload) }
///         .receive("error") { payload in print("Send failed", payload) }
///         .receive("timeout") { payload in print("Networking issue...", payload) }
///
///     channel.join()
///         .receive("ok") { payload in print("Channel Joined", payload) }
///         .receive("error") { payload in print("Failed ot join", payload) }
///         .receive("timeout") { payload in print("Networking issue...", payload) }
///

import Foundation

public enum ChannelError: Error {
  case alreadyJoined
  case pushBeforeJoin(topic: String, event: String)
}

@MainActor
public class Channel {
  
  /// The topic of the Channel. e.g. "rooms:friends"
  public let topic: String
  
  /// The params sent when joining the channel
  public var params: Payload {
    didSet { self.joinPush.payload = params }
  }
  
  /// The Socket that the channel belongs to
  weak var socket: Socket?
  
  /// Current state of the Channel
  var state: ChannelState
  
  /// Collection of event bindings
  var syncBindingsDel: [Binding]
  
  /// Tracks event binding ref counters
  var bindingRef: Int
  
  /// Timout when attempting to join a Channel
  var timeout: TimeInterval
  
  /// Set to true once the channel calls .join()
  var joinedOnce: Bool
  
  /// Push to send when the channel calls .join()
  var joinPush: Push!
  
  /// Buffer of Pushes that will be sent once the Channel's socket connects
  var pushBuffer: [Push]
  
  /// Scheduler for delayed rejoin attempts
  let scheduler: any PhoenixScheduler

  /// One-shot schedule token for channel rejoin
  private var rejoinSchedule: PhoenixSchedulerToken?

  /// Rejoin attempt counter used for backoff calculation
  private var rejoinAttempts = 0
  
  /// Refs of stateChange hooks
  var stateChangeRefs: [String]
  
  /// Initialize a Channel
  ///
  /// - parameter topic: Topic of the Channel
  /// - parameter params: Optional. Parameters to send when joining.
  /// - parameter socket: Socket that the channel is a part of
  init(topic: String,
       params: Payload = [:],
       socket: Socket,
       scheduler: any PhoenixScheduler) {
    self.state = ChannelState.closed
    self.topic = topic
    self.params = params
    self.socket = socket
    self.scheduler = scheduler
    self.syncBindingsDel = []
    self.bindingRef = 0
    self.timeout = socket.timeout
    self.joinedOnce = false
    self.pushBuffer = []
    self.stateChangeRefs = []
    // Respond to socket events
    let onErrorRef = self.socket?.onError(callback: { [weak self] _ in
      self?.resetRejoinSchedule()
    })
    if let ref = onErrorRef { self.stateChangeRefs.append(ref) }
  
    let onOpenRef = self.socket?.onOpen(callback: { [weak self] in
      guard let self else { return }
      self.resetRejoinSchedule()
      if self.isErrored { self.rejoin() }
    })
    if let ref = onOpenRef { self.stateChangeRefs.append(ref) }
    
    // Setup Push Event to be sent when joining
    self.joinPush = Push(channel: self,
                         event: ChannelEvent.join,
                         payload: self.params,
                         timeout: self.timeout)
    
    /// Handle when a response is received after join()
    self.joinPush.receive("ok") { [weak self] _ in
      guard let self else { return }
      // Mark the Channel as joined
      self.state = ChannelState.joined
      
      // Reset the timer, preventing it from attempting to join again
      self.resetRejoinSchedule()
      
      // Send and buffered messages and clear the buffer
      self.pushBuffer.forEach( { $0.send() })
      self.pushBuffer = []
    }
    
    // Perform if Channel errors while attempting to joi
    self.joinPush.receive("error") { [weak self] _ in
      guard let self else { return }
      self.state = .errored
      if (self.socket?.isConnected == true) { self.scheduleRejoin() }
    }
    
    // Handle when the join push times out when sending after join()
    self.joinPush.receive("timeout") { [weak self] _ in
      guard let self else { return }
      // log that the channel timed out
      self.socket?.logDebug(
        category: "channel",
        message: "timeout",
        metadata: ["topic": self.topic, "joinRef": self.joinRef ?? "", "timeout": String(self.timeout)]
      )
      
      // Send a Push to the server to leave the channel
      let leavePush = Push(channel: self,
                           event: ChannelEvent.leave,
                           timeout: self.timeout)
      leavePush.send()
      
      // Mark the Channel as in an error and attempt to rejoin if socket is connected
      self.state = ChannelState.errored
      self.joinPush.reset()
      
      if (self.socket?.isConnected == true) { self.scheduleRejoin() }
    }
    
    /// Perfom when the Channel has been closed
    self.onClose { [weak self] _ in
      guard let self else { return }
      // Reset any timer that may be on-going
      self.resetRejoinSchedule()
      
      // Log that the channel was left
      self.socket?.logDebug(
        category: "channel",
        message: "closed",
        metadata: ["topic": self.topic, "joinRef": self.joinRef ?? "nil"]
      )
      
      // Mark the channel as closed and remove it from the socket
      self.state = ChannelState.closed
      self.socket?.remove(self)
    }
    
    /// Perfom when the Channel errors
    self.onError { [weak self] message in
      guard let self else { return }
      // Log that the channel received an error
      self.socket?.logDebug(
        category: "channel",
        message: "error",
        metadata: ["topic": self.topic, "joinRef": self.joinRef ?? "nil", "event": message.event]
      )
      
      // If error was received while joining, then reset the Push
      if (self.isJoining) {
        // Make sure that the "phx_join" isn't buffered to send once the socket
        // reconnects. The channel will send a new join event when the socket connects.
        if let safeJoinRef = self.joinRef {
          self.socket?.removeFromSendBuffer(ref: safeJoinRef)
        }
        
        // Reset the push to be used again later
        self.joinPush.reset()
      }
      
      // Mark the channel as errored and attempt to rejoin if socket is currently connected
      self.state = ChannelState.errored
      if (self.socket?.isConnected == true) { self.scheduleRejoin() }
    }
    
    // Perform when the join reply is received
    self.on(ChannelEvent.reply) { [weak self] message in
      guard let self else { return }
      // Trigger bindings
      self.trigger(event: self.replyEventName(message.ref),
                   payload: message.rawPayload,
                   ref: message.ref,
                   joinRef: message.joinRef)
    }
  }
  
  /// Overridable message hook. Receives all events for specialized message
  /// handling before dispatching to the channel callbacks.
  ///
  /// - parameter msg: The Message received by the client from the server
  /// - return: Must return the message, modified or unmodified
  public var onMessage: (_ message: Message) -> Message = { (message) in
    return message
  }
  
  /// Joins the channel
  ///
  /// - parameter timeout: Optional. Defaults to Channel's timeout
  /// - return: Push event
  @discardableResult
  public func join(timeout: TimeInterval? = nil) throws -> Push {
    guard !joinedOnce else {
      throw ChannelError.alreadyJoined
    }
    
    // Join the Channel
    if let safeTimeout = timeout { self.timeout = safeTimeout }
    
    self.joinedOnce = true
    self.rejoin()
    return joinPush
  }
  
  
  /// Hook into when the Channel is closed. Does not handle retain cycles.
  /// Capture weak references in your callback as needed.
  ///
  /// Example:
  ///
  ///     let channel = socket.channel("topic")
  ///     channel.onClose() { [weak self] message in
  ///         self?.print("Channel \(message.topic) has closed"
  ///     }
  ///
  /// - parameter callback: Called when the Channel closes
  /// - return: Ref counter of the subscription. See `func off()`
  @discardableResult
  public func onClose(_ callback: @escaping ((Message) -> Void)) -> Int {
    return self.on(ChannelEvent.close, callback: callback)
  }
  
  /// Hook into when the Channel receives an Error. Does not handle retain
  /// cycles. Capture weak references in your callback as needed.
  ///
  /// Example:
  ///
  ///     let channel = socket.channel("topic")
  ///     channel.onError() { [weak self] (message) in
  ///         self?.print("Channel \(message.topic) has errored"
  ///     }
  ///
  /// - parameter callback: Called when the Channel closes
  /// - return: Ref counter of the subscription. See `func off()`
  @discardableResult
  public func onError(_ callback: @escaping ((_ message: Message) -> Void)) -> Int {
    return self.on(ChannelEvent.error, callback: callback)
  }
  
  /// Subscribes on channel events. Does not handle retain cycles.
  ///
  /// Subscription returns a ref counter, which can be used later to
  /// unsubscribe the exact event listener
  ///
  /// Example:
  ///
  ///     let channel = socket.channel("topic")
  ///     let ref1 = channel.on("event") { [weak self] (message) in
  ///         self?.print("do stuff")
  ///     }
  ///     let ref2 = channel.on("event") { [weak self] (message) in
  ///         self?.print("do other stuff")
  ///     }
  ///     channel.off("event", ref1)
  ///
  /// Since unsubscription of ref1, "do stuff" won't print, but "do other
  /// stuff" will keep on printing on the "event"
  ///
  /// - parameter event: Event to receive
  /// - parameter callback: Called with the event's message
  /// - return: Ref counter of the subscription. See `func off()`
  @discardableResult
  public func on(_ event: String, callback: @escaping ((Message) -> Void)) -> Int {
    let ref = bindingRef
    self.bindingRef = ref + 1
    
    self.syncBindingsDel.append(Binding(event: event, ref: ref, callback: callback))
    return ref
  }

  @discardableResult
  public func on(_ event: PhoenixEvent, callback: @escaping ((Message) -> Void)) -> Int {
    self.on(event.rawValue, callback: callback)
  }
  
  /// Unsubscribes from a channel event. If a `ref` is given, only the exact
  /// listener will be removed. Else all listeners for the `event` will be
  /// removed.
  ///
  /// Example:
  ///
  ///     let channel = socket.channel("topic")
  ///     let ref1 = channel.on("event") { _ in print("ref1 event" }
  ///     let ref2 = channel.on("event") { _ in print("ref2 event" }
  ///     let ref3 = channel.on("other_event") { _ in print("ref3 other" }
  ///     let ref4 = channel.on("other_event") { _ in print("ref4 other" }
  ///     channel.off("event", ref1)
  ///     channel.off("other_event")
  ///
  /// After this, only "ref2 event" will be printed if the channel receives
  /// "event" and nothing is printed if the channel receives "other_event".
  ///
  /// - parameter event: Event to unsubscribe from
  /// - paramter ref: Ref counter returned when subscribing. Can be omitted
  public func off(_ event: String, ref: Int? = nil) {
    self.syncBindingsDel.removeAll { (bind) -> Bool in
      bind.event == event && (ref == nil || ref == bind.ref)
    }
  }

  public func off(_ event: PhoenixEvent, ref: Int? = nil) {
    self.off(event.rawValue, ref: ref)
  }
  
  /// Push a payload to the Channel
  ///
  /// Example:
  ///
  ///     channel
  ///         .push("event", payload: ["message": "hello")
  ///         .receive("ok") { _ in { print("message sent") }
  ///
  /// - parameter event: Event to push
  /// - parameter payload: Payload to push
  /// - parameter timeout: Optional timeout
  @discardableResult
  public func push(_ event: String,
                   payload: Payload,
                   timeout: TimeInterval = Defaults.timeoutInterval) throws -> Push {
    guard joinedOnce else { throw ChannelError.pushBeforeJoin(topic: self.topic, event: event) }
    
    let pushEvent = Push(channel: self,
                         event: event,
                         payload: payload,
                         timeout: timeout)
    if canPush {
      pushEvent.send()
    } else {
      pushEvent.startTimeout()
      pushBuffer.append(pushEvent)
    }
    
    return pushEvent
  }

  @discardableResult
  public func push(_ event: PhoenixEvent,
                   payload: Payload,
                   timeout: TimeInterval = Defaults.timeoutInterval) throws -> Push {
    try self.push(event.rawValue, payload: payload, timeout: timeout)
  }
  
  /// Leaves the channel
  ///
  /// Unsubscribes from server events, and instructs channel to terminate on
  /// server
  ///
  /// Triggers onClose() hooks
  ///
  /// To receive leave acknowledgements, use the a `receive`
  /// hook to bind to the server ack, ie:
  ///
  /// Example:
  ////
  ///     channel.leave().receive("ok") { _ in { print("left") }
  ///
  /// - parameter timeout: Optional timeout
  /// - return: Push that can add receive hooks
  @discardableResult
  public func leave(timeout: TimeInterval = Defaults.timeoutInterval) -> Push {
    // If attempting a rejoin during a leave, then reset, cancelling the rejoin
    self.resetRejoinSchedule()
    
    // Now set the state to leaving
    self.state = .leaving
    
    /// Delegated callback for a successful or a failed channel leave
    let onCloseCallback: (Message) -> Void = { [weak self] _ in
      guard let self else { return }
      self.socket?.logDebug(category: "channel", message: "leave", metadata: ["topic": self.topic])
      
      // Triggers onClose() hooks
      self.trigger(event: ChannelEvent.close, payload: ["reason": "leave"])
    }
    
    // Push event to send to the server
    let leavePush = Push(channel: self,
                         event: ChannelEvent.leave,
                         timeout: timeout)
    
    // Perform the same behavior if successfully left the channel
    // or if sending the event timed out
    leavePush
      .receive("ok", callback: onCloseCallback)
      .receive("timeout", callback: onCloseCallback)
    leavePush.send()
    
    // If the Channel cannot send push events, trigger a success locally
    if !canPush { leavePush.trigger("ok", payload: [:]) }
    
    // Return the push so it can be bound to
    return leavePush
  }
  
  /// Overridable message hook. Receives all events for specialized message
  /// handling before dispatching to the channel callbacks.
  ///
  /// - parameter event: The event the message was for
  /// - parameter payload: The payload for the message
  /// - parameter ref: The reference of the message
  /// - return: Must return the payload, modified or unmodified
  public func onMessage(callback: @escaping (Message) -> Message) {
    self.onMessage = callback
  }
  
  
  //----------------------------------------------------------------------
  // MARK: - Internal
  //----------------------------------------------------------------------
  /// Checks if an event received by the Socket belongs to this Channel
  func isMember(_ message: Message) -> Bool {
    // Return false if the message's topic does not match the Channel's topic
    guard message.topic == self.topic else { return false }

    guard
      let safeJoinRef = message.joinRef,
      safeJoinRef != self.joinRef,
      ChannelEvent.isLifecyleEvent(message.event)
      else { return true }

    self.socket?.logDebug(
      category: "channel",
      message: "dropping outdated message",
      metadata: ["topic": message.topic, "event": message.event, "joinRef": safeJoinRef]
    )
    return false
  }
  
  /// Sends the payload to join the Channel
  func sendJoin(_ timeout: TimeInterval) {
    self.state = ChannelState.joining
    self.joinPush.resend(timeout)
  }
  
  /// Rejoins the channel
  func rejoin(_ timeout: TimeInterval? = nil) {
    // Do not attempt to rejoin if the channel is in the process of leaving
    guard !self.isLeaving else { return }
    
    // Leave potentially duplicate channels
    self.socket?.leaveOpenTopic(topic: self.topic)
    
    // Send the joinPush
    self.sendJoin(timeout ?? self.timeout)
  }
  
  /// Triggers an event to the correct event bindings created by
  /// `channel.on("event")`.
  ///
  /// - parameter message: Message to pass to the event bindings
  func trigger(_ message: Message) {
    let handledMessage = self.onMessage(message)
    
    self.syncBindingsDel.forEach { binding in
        if binding.event == message.event {
            binding.callback(handledMessage)
        }
    }
  }
  
  /// Triggers an event to the correct event bindings created by
  //// `channel.on("event")`.
  ///
  /// - parameter event: Event to trigger
  /// - parameter payload: Payload of the event
  /// - parameter ref: Ref of the event. Defaults to empty
  /// - parameter joinRef: Ref of the join event. Defaults to nil
  func trigger(event: String,
               payload: Payload = [:],
               ref: String = "",
               joinRef: String? = nil) {
    let message = Message(ref: ref,
                          topic: self.topic,
                          event: event,
                          payload: payload,
                          joinRef: joinRef ?? self.joinRef)
    self.trigger(message)
  }
  
  /// - parameter ref: The ref of the event push
  /// - return: The event name of the reply
  func replyEventName(_ ref: String) -> String {
    return "chan_reply_\(ref)"
  }
  
  /// The Ref send during the join message.
  var joinRef: String? {
    return self.joinPush.ref
  }
  
  /// - return: True if the Channel can push messages, meaning the socket
  ///           is connected and the channel is joined
  var canPush: Bool {
    return self.socket?.isConnected == true && self.isJoined
  }

  private func resetRejoinSchedule() {
    self.rejoinAttempts = 0
    self.scheduler.cancel(self.rejoinSchedule)
    self.rejoinSchedule = nil
  }

  private func scheduleRejoin() {
    self.scheduler.cancel(self.rejoinSchedule)
    self.rejoinAttempts += 1

    let interval = self.socket?.rejoinAfter(self.rejoinAttempts) ?? 5.0
    self.rejoinSchedule = self.scheduler.scheduleOnce(after: interval, tolerance: nil) { [weak self] in
      guard let self else { return }
      if self.socket?.isConnected == true {
        self.rejoin()
      }
    }
  }
}


//----------------------------------------------------------------------
// MARK: - Public API
//----------------------------------------------------------------------
extension Channel {
  
  /// - return: True if the Channel has been closed
  public var isClosed: Bool {
    return state == .closed
  }
  
  /// - return: True if the Channel experienced an error
  public var isErrored: Bool {
    return state == .errored
  }
  
  /// - return: True if the channel has joined
  public var isJoined: Bool {
    return state == .joined
  }
  
  /// - return: True if the channel has requested to join
  public var isJoining: Bool {
    return state == .joining
  }
  
  /// - return: True if the channel has requested to leave
  public var isLeaving: Bool {
    return state == .leaving
  }
  
}

public enum ChannelAsyncError: Error {
  case closed
}

extension Channel {
  /// AsyncStream wrapper for channel events.
  public func messages(event: String,
                       bufferingPolicy: AsyncStream<Message>.Continuation.BufferingPolicy = .unbounded)
  -> AsyncStream<Message> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      let ref = self.on(event) { message in
        continuation.yield(message)
      }

      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.off(event, ref: ref)
        }
      }
    }
  }

  public func messages(event: PhoenixEvent,
                       bufferingPolicy: AsyncStream<Message>.Continuation.BufferingPolicy = .unbounded)
  -> AsyncStream<Message> {
    self.messages(event: event.rawValue, bufferingPolicy: bufferingPolicy)
  }

  /// Async join that returns the join reply message.
  public func joinAsync(timeout: TimeInterval? = nil) async throws -> Message {
    let push = try self.join(timeout: timeout)
    return try await push.responseAsync()
  }

  /// Async push that returns the push reply message.
  public func pushAsync(_ event: String,
                        payload: Payload,
                        timeout: TimeInterval = Defaults.timeoutInterval) async throws -> Message {
    let push = try self.push(event, payload: payload, timeout: timeout)
    return try await push.responseAsync()
  }

  public func pushAsync(_ event: PhoenixEvent,
                        payload: Payload,
                        timeout: TimeInterval = Defaults.timeoutInterval) async throws -> Message {
    try await self.pushAsync(event.rawValue, payload: payload, timeout: timeout)
  }

  /// Async leave that returns the leave reply message.
  public func leaveAsync(timeout: TimeInterval = Defaults.timeoutInterval) async throws -> Message {
    let push = self.leave(timeout: timeout)
    return try await push.responseAsync()
  }
}
