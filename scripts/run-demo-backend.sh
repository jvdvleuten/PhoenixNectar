#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOENIX_DIR="${ROOT_DIR}/e2e/nectar_hive"

cd "${PHOENIX_DIR}"

if [ ! -d "_build" ] || [ ! -d "deps" ]; then
  mix setup
fi

exec mix phx.server
