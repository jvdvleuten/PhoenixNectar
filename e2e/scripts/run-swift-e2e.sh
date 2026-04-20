#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHX_DIR="$ROOT/e2e/nectar_hive"

PORT="${PORT:-4000}"
E2E_URL="${PHOENIX_E2E_URL:-ws://127.0.0.1:${PORT}/socket}"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-.build-e2e}"
DEMO_URL="http://127.0.0.1:${PORT}/chat_demo.html"
DEMO_RESPONSE="/tmp/phoenixnectar-e2e-demo.html"
DEMO_HEADERS="/tmp/phoenixnectar-e2e-demo.headers"

cd "$PHX_DIR"
echo "--- mix deps.get ---"
mix deps.get || { echo "mix deps.get failed" >&2; exit 1; }
echo "--- mix compile ---"
mix compile || { echo "mix compile failed" >&2; exit 1; }

MIX_ENV=dev PORT="$PORT" mix phx.server > /tmp/phoenixnectar-e2e-phx.log 2>&1 &
PHX_PID=$!

cleanup() {
  kill "$PHX_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- Waiting for Phoenix on port ${PORT} ---"
for _ in {1..120}; do
  status="$(
    curl -sS \
      --connect-timeout 2 \
      --max-time 5 \
      --output "$DEMO_RESPONSE" \
      --dump-header "$DEMO_HEADERS" \
      --write-out "%{http_code}" \
      "$DEMO_URL" 2>/dev/null || true
  )"

  if [[ "$status" == "200" ]] && grep -q "PhoenixNectar Chat Demo" "$DEMO_RESPONSE"; then
    break
  fi

  if ! kill -0 "$PHX_PID" >/dev/null 2>&1; then
    echo "Phoenix server exited before becoming ready" >&2
    cat /tmp/phoenixnectar-e2e-phx.log >&2 || true
    exit 1
  fi
  sleep 0.25
done

if [[ "${status:-}" != "200" ]] || ! grep -q "PhoenixNectar Chat Demo" "$DEMO_RESPONSE"; then
  echo "Phoenix server did not become ready on port ${PORT}" >&2
  echo "--- Last readiness response status ---" >&2
  echo "${status:-<no response>}" >&2
  echo "--- Last readiness response headers ---" >&2
  cat "$DEMO_HEADERS" >&2 || true
  echo "--- Last readiness response body excerpt ---" >&2
  head -c 2000 "$DEMO_RESPONSE" >&2 || true
  echo >&2
  echo "--- Phoenix log ---" >&2
  cat /tmp/phoenixnectar-e2e-phx.log >&2 || true
  exit 1
fi
echo "Phoenix server ready on port ${PORT}"

cd "$ROOT"
echo "--- Running Swift E2E tests ---"
PHOENIX_E2E_URL="$E2E_URL" swift test --scratch-path "$SWIFT_SCRATCH_PATH" --filter PhoenixE2ETests
