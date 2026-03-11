# E2E Harness

This folder contains a real Phoenix server used for end-to-end channel validation against `PhoenixNectar`.

## Phoenix App

- App: `e2e/nectar_hive`
- Phoenix: `~> 1.8.5`
- Declared Elixir requirement: `~> 1.15`
- CI-tested backend floor: Phoenix `1.8.4+`, Elixir `1.18+`
- Socket endpoint: `/socket`
- Channels:
  - `room:lobby` (basic sample events)
  - `private:room:<room_id>` (private chatroom auth via transport `authToken`, plus params metadata like `device_id`)
- Demo web app:
  - `/chat_demo.html` static page
  - self-contained browser WebSocket demo for shared-room chat

## Fastest Local Demo

From the repo root:

```bash
./scripts/run-demo-backend.sh
open demos/ChatShowcaseApp/ChatShowcaseApp.xcodeproj
```

Then open:

```text
http://127.0.0.1:4000/chat_demo.html
```

Use the same room in browser and iOS, but different users, to see shared-room chat.

## Run E2E

From repo root:

```bash
./e2e/scripts/run-swift-e2e.sh
```

This script:

1. starts Phoenix (`mix phx.server`) on `127.0.0.1:4000`
2. runs `swift test --filter PhoenixE2ETests`
3. stops the Phoenix server

## Override URL / Port

```bash
PORT=4100 PHOENIX_E2E_URL=ws://127.0.0.1:4100/socket ./e2e/scripts/run-swift-e2e.sh
```

## CI

GitHub Actions runs two E2E layers:

- `E2E (macOS + Phoenix)`
  - Runs the full Swift + Phoenix E2E flow via `./e2e/scripts/run-swift-e2e.sh`
  - Keeps client/server integration coverage on macOS
- `E2E Backend Contract (Linux, Phoenix ..., Elixir ... )`
  - Runs Phoenix backend tests (`mix test` in `e2e/nectar_hive`) on Linux
  - Uses a version matrix to pin Phoenix per job:
    - current stable track: Phoenix `1.8.5` + Elixir `1.19` / OTP `28`
    - previous stable track: Phoenix `1.8.4` + Elixir `1.18` / OTP `27`
  - Validates backend contract compatibility across Phoenix/Elixir combinations without altering Swift jobs

## Related

- Main guide: `README.md`
- Full API: `Docs/API-Reference.md`
