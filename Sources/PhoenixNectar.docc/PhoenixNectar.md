# ``PhoenixNectar``

Actor-first Phoenix Channels client for Swift 6.

## Overview

PhoenixNectar wraps the Phoenix Channels protocol in a Swift-native API built around actors, `async`/`await`, and typed request/reply/event contracts.

The typical application flow is:

1. Create a ``Socket``
2. Call ``Socket/connect()``
3. Join a topic with ``Socket/joinChannel(_:policy:)`` or, if the server expects a join payload, ``Socket/joinChannel(_:params:policy:)``
4. Subscribe to inbound events with ``Channel/subscribe(to:bufferingPolicy:)``
5. Send typed pushes with ``Channel/push(_:payload:policy:)``

### Connection Behavior

- Provider closures (`authTokenProvider`, `connectParamsProvider`) are re-evaluated on each connect and reconnect
- Unexpected transport loss triggers reconnect with configurable backoff
- Joined topics are automatically rejoined after reconnect
- Heartbeat timeout follows the same reconnect path
- Server-initiated clean close (code 1000) reconnects by default — disable with ``ConnectionPolicy/reconnectOnCleanClose``
- Explicit ``Socket/disconnect(code:reason:)`` is treated as intentional and does not auto-reconnect

### Lower-Level APIs

The same module also exposes lower-level APIs for custom integrations:

- ``Socket/Configuration``, ``RequestPolicy``, and ``ConnectionPolicy``
- ``PhoenixReply`` for raw reply status and payload inspection
- ``Socket/setLogger(_:)`` with `OSLog.Logger` and ``Socket/setMetricsHook(_:)``
- ``Socket/connectionStateStream(bufferingPolicy:)``
- ``Socket/ping(policy:)``
- ``Channel/subscribeBinary(to:bufferingPolicy:)``

## Topics

- <doc:GettingStarted>
- ``Socket``
- ``Channel``
- ``Topic``
- ``Push``
- ``Event``
- ``PhoenixMessage``
- ``PhoenixReply``
- ``RequestPolicy``
- ``ConnectionPolicy``
