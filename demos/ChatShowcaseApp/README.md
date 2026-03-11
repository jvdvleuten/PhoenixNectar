# ChatShowcaseApp

This is a real Xcode SwiftUI app project (not package-only) that demonstrates PhoenixNectar against the local E2E backend.

## Fastest Run Path

From the repository root:

```bash
./scripts/run-demo-backend.sh
open demos/ChatShowcaseApp/ChatShowcaseApp.xcodeproj
```

Then run `ChatShowcaseApp` on an iOS 17+ simulator.

The browser demo lives at:

```text
http://127.0.0.1:4000/chat_demo.html
```

Use the same room in browser and iOS, but different users.

## Open In Xcode

The committed Xcode project is ready to open directly:

```bash
open ChatShowcaseApp.xcodeproj
```

If you change `project.yml`, regenerate the project with:

```bash
cd demos/ChatShowcaseApp
xcodegen generate
```

## Backend

Start the local Phoenix E2E backend first:

```bash
./scripts/run-demo-backend.sh
```

Default app endpoint is `ws://127.0.0.1:4000/socket`.

Auth in this demo uses `authTokenProvider` with token format `user:<user_id>`.

## What it shows

- connect/disconnect
- authenticated private channel join
- typed push + typed event subscription
- binary push (`binary:upload`) using selected image bytes
