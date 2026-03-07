import Foundation

@MainActor
public final class Presence {
  public struct Options: Sendable {
    let events: [Events: String]
    static public let defaults = Options(events: [.state: "presence_state", .diff: "presence_diff"])

    public init(events: [Events: String]) {
      self.events = events
    }
  }

  public enum Events: String, Sendable {
    case state = "state"
    case diff = "diff"
  }

  public typealias Meta = [String: PhoenixValue]
  public typealias Map = [String: [Meta]]
  public typealias State = [String: Map]
  public typealias Diff = [String: State]

  public typealias OnJoin = (_ key: String, _ current: Map?, _ new: Map) -> Void
  public typealias OnLeave = (_ key: String, _ current: Map, _ left: Map) -> Void
  public typealias OnSync = () -> Void

  struct Caller {
    var onJoin: OnJoin = { _, _, _ in }
    var onLeave: OnLeave = { _, _, _ in }
    var onSync: OnSync = {}
  }

  weak var channel: Channel?
  var caller: Caller
  private(set) public var state: State
  private(set) public var pendingDiffs: [Diff]
  private(set) public var joinRef: String?

  public var isPendingSyncState: Bool {
    guard let safeJoinRef = self.joinRef else { return true }
    return safeJoinRef != self.channel?.joinRef
  }

  public var onJoin: OnJoin {
    get { caller.onJoin }
    set { caller.onJoin = newValue }
  }

  public func onJoin(_ callback: @escaping OnJoin) {
    self.onJoin = callback
  }

  public var onLeave: OnLeave {
    get { caller.onLeave }
    set { caller.onLeave = newValue }
  }

  public func onLeave(_ callback: @escaping OnLeave) {
    self.onLeave = callback
  }

  public var onSync: OnSync {
    get { caller.onSync }
    set { caller.onSync = newValue }
  }

  public func onSync(_ callback: @escaping OnSync) {
    self.onSync = callback
  }

  public init(channel: Channel, opts: Options = Options.defaults) {
    self.state = [:]
    self.pendingDiffs = []
    self.channel = channel
    self.joinRef = nil
    self.caller = Caller()

    guard let stateEvent = opts.events[.state], let diffEvent = opts.events[.diff] else { return }

    self.channel?.on(stateEvent) { [weak self] message in
      guard let self else { return }
      guard let newState = Self.decodeState(message.rawPayload) else { return }

      self.joinRef = self.channel?.joinRef
      self.state = Self.syncState(self.state,
                                  newState: newState,
                                  onJoin: self.caller.onJoin,
                                  onLeave: self.caller.onLeave)

      self.pendingDiffs.forEach { diff in
        self.state = Self.syncDiff(self.state,
                                   diff: diff,
                                   onJoin: self.caller.onJoin,
                                   onLeave: self.caller.onLeave)
      }

      self.pendingDiffs.removeAll()
      self.caller.onSync()
    }

    self.channel?.on(diffEvent) { [weak self] message in
      guard let self else { return }
      guard let diff = Self.decodeDiff(message.rawPayload) else { return }
      if self.isPendingSyncState {
        self.pendingDiffs.append(diff)
      } else {
        self.state = Self.syncDiff(self.state,
                                   diff: diff,
                                   onJoin: self.caller.onJoin,
                                   onLeave: self.caller.onLeave)
        self.caller.onSync()
      }
    }
  }

  public func list() -> [Map] {
    self.list(by: { _, pres in pres })
  }

  public func list<T>(by transformer: (String, Map) -> T) -> [T] {
    Self.listBy(self.state, transformer: transformer)
  }

  public func filter(by filter: ((String, Map) -> Bool)?) -> State {
    Self.filter(self.state, by: filter)
  }

  @discardableResult
  public static func syncState(_ currentState: State,
                               newState: State,
                               onJoin: OnJoin = { _, _, _ in },
                               onLeave: OnLeave = { _, _, _ in }) -> State {
    let state = currentState
    var leaves: State = [:]
    var joins: State = [:]

    state.forEach { key, presence in
      if newState[key] == nil {
        leaves[key] = presence
      }
    }

    newState.forEach { key, newPresence in
      if let currentPresence = state[key] {
        let newRefs = refs(from: newPresence)
        let curRefs = refs(from: currentPresence)

        let joinedMetas = metas(from: newPresence).filter { meta in
          guard let ref = meta["phx_ref"]?.stringValue else { return false }
          return !curRefs.contains(ref)
        }
        let leftMetas = metas(from: currentPresence).filter { meta in
          guard let ref = meta["phx_ref"]?.stringValue else { return false }
          return !newRefs.contains(ref)
        }

        if !joinedMetas.isEmpty {
          joins[key] = newPresence
          joins[key]?["metas"] = joinedMetas
        }

        if !leftMetas.isEmpty {
          leaves[key] = currentPresence
          leaves[key]?["metas"] = leftMetas
        }
      } else {
        joins[key] = newPresence
      }
    }

    return syncDiff(state, diff: ["joins": joins, "leaves": leaves], onJoin: onJoin, onLeave: onLeave)
  }

  @discardableResult
  public static func syncDiff(_ currentState: State,
                              diff: Diff,
                              onJoin: OnJoin = { _, _, _ in },
                              onLeave: OnLeave = { _, _, _ in }) -> State {
    var state = currentState

    diff["joins"]?.forEach { key, newPresence in
      let currentPresence = state[key]
      state[key] = newPresence

      if let currentPresence {
        let joinedRefs = refs(from: newPresence)
        let curMetas = metas(from: currentPresence).filter { meta in
          guard let ref = meta["phx_ref"]?.stringValue else { return false }
          return !joinedRefs.contains(ref)
        }
        state[key]?["metas", default: []].insert(contentsOf: curMetas, at: 0)
      }

      onJoin(key, currentPresence, newPresence)
    }

    diff["leaves"]?.forEach { key, leftPresence in
      guard var currentPresence = state[key] else { return }
      let refsToRemove = refs(from: leftPresence)
      let keepMetas = metas(from: currentPresence).filter { meta in
        guard let ref = meta["phx_ref"]?.stringValue else { return false }
        return !refsToRemove.contains(ref)
      }

      currentPresence["metas"] = keepMetas
      onLeave(key, currentPresence, leftPresence)

      if keepMetas.isEmpty {
        state.removeValue(forKey: key)
      } else {
        state[key] = currentPresence
      }
    }

    return state
  }

  public static func filter(_ presences: State,
                            by filter: ((String, Map) -> Bool)?) -> State {
    let safeFilter = filter ?? { _, _ in true }
    return presences.filter(safeFilter)
  }

  public static func listBy<T>(_ presences: State,
                               transformer: (String, Map) -> T) -> [T] {
    presences.map(transformer)
  }

  private static func decodeState(_ payload: Payload) -> State? {
    var result: State = [:]

    for (key, value) in payload {
      guard let object = value.objectValue else { return nil }
      var map: Map = [:]

      for (mapKey, mapValue) in object {
        guard let metasArray = mapValue.arrayValue else { return nil }
        let metas = metasArray.compactMap { $0.objectValue }
        map[mapKey] = metas
      }

      result[key] = map
    }

    return result
  }

  private static func decodeDiff(_ payload: Payload) -> Diff? {
    guard let joinsObject = payload["joins"]?.objectValue,
          let leavesObject = payload["leaves"]?.objectValue,
          let joins = decodeState(joinsObject),
          let leaves = decodeState(leavesObject)
    else {
      return nil
    }

    return ["joins": joins, "leaves": leaves]
  }

  private static func metas(from map: Map) -> [Meta] {
    map["metas"] ?? []
  }

  private static func refs(from map: Map) -> [String] {
    metas(from: map).compactMap { $0["phx_ref"]?.stringValue }
  }
}
