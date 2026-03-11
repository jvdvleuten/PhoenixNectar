#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHX_DIR="$ROOT/e2e/nectar_hive"

PORT="${PORT:-4000}"
E2E_URL="${PHOENIX_E2E_URL:-ws://127.0.0.1:${PORT}/socket}"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-.build-e2e}"

cd "$PHX_DIR"
mix deps.get >/dev/null
mix compile >/dev/null

MIX_ENV=dev PORT="$PORT" mix phx.server > /tmp/phoenixnectar-e2e-phx.log 2>&1 &
PHX_PID=$!

cleanup() {
  kill "$PHX_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in {1..120}; do
  if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$PHX_PID" >/dev/null 2>&1; then
    echo "Phoenix server exited before becoming ready" >&2
    cat /tmp/phoenixnectar-e2e-phx.log >&2 || true
    exit 1
  fi
  sleep 0.25
done

if ! curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
  echo "Phoenix server did not become ready on port ${PORT}" >&2
  cat /tmp/phoenixnectar-e2e-phx.log >&2 || true
  exit 1
fi

curl -fsS "http://127.0.0.1:${PORT}/chat_demo.html" | grep -q "PhoenixNectar Chat Demo"

cd "$ROOT"
PHOENIX_E2E_URL="$E2E_URL" swift test --scratch-path "$SWIFT_SCRATCH_PATH" --filter PhoenixE2ETests
