#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHX_DIR="$ROOT/e2e/nectar_hive"

PHOENIX_REQUIREMENT="${PHOENIX_REQUIREMENT:-== 1.8.5}"

cd "$PHX_DIR"

mix deps.get
mix test
