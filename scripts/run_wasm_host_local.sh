#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

set -a
source ./configs/bench.env
set +a

: "${WASM_MODULE_PATH:=$ROOT/gateway_logic.wasm}"
export WASM_MODULE_PATH

exec "$ROOT/target/release/gateway_host"
