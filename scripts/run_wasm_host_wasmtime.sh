#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

set -a
source ./configs/bench.env
set +a

PORT="${PORT:-18081}"
LISTEN_HOST="127.0.0.1"
if [[ "${LISTEN:-}" == *:* ]]; then
  LISTEN_HOST="${LISTEN%:*}"
fi
LISTEN="${LISTEN_HOST}:${PORT}"

: "${WASM_MODULE_PATH:=$ROOT/gateway_logic.wasm}"
export WASM_MODULE_PATH
export WASM_RUNTIME="wasmtime"
export LISTEN

echo "[run_wasm_host_wasmtime] LISTEN=$LISTEN WASM_RUNTIME=$WASM_RUNTIME WASM_MODULE_PATH=$WASM_MODULE_PATH" >&2

exec "$ROOT/target/release/gateway_host"
