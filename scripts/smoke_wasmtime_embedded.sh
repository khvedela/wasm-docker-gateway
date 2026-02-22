#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl

PORT="${PORT:-18081}"

cd "$ROOT"
start_upstream
./scripts/build_wasm.sh

log "building gateway_host release binary"
cargo build --release --bin gateway_host

set -a
source "$ROOT/configs/bench.env"
set +a

export LISTEN="127.0.0.1:${PORT}"
export WASM_RUNTIME="wasmtime_embedded"
export WASM_MODULE_PATH="${WASM_MODULE_PATH:-$ROOT/gateway_logic.wasm}"

GW_LOG="$RESULTS_DIR/smoke_wasmtime_embedded_${TS}.log"

cleanup() {
  if [[ -n "${GW_PID:-}" ]]; then
    kill "${GW_PID}" >/dev/null 2>&1 || true
    sleep 0.1
    kill -9 "${GW_PID}" >/dev/null 2>&1 || true
    wait "${GW_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

log "starting gateway_host with embedded Wasmtime"
"$ROOT/target/release/gateway_host" >"$GW_LOG" 2>&1 &
GW_PID=$!

wait_http_200 "http://127.0.0.1:${PORT}/health" 200 0.02
curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/compute?iters=10" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/state" >/dev/null

hdr="$(mktemp)"
body="$(mktemp)"
curl -fsS --max-time 5 -D "$hdr" -o "$body" "http://127.0.0.1:${PORT}/foo"

if ! grep -qi '^x-wasm-processed:[[:space:]]*1[[:space:]]*$' "$hdr"; then
  echo "ERROR: missing x-wasm-processed: 1 header on /foo response" >&2
  echo "--- headers ---" >&2
  cat "$hdr" >&2
  exit 1
fi

if ! head -c 5 "$body" | grep -q '^wasm:'; then
  echo "ERROR: /foo body does not start with 'wasm:'" >&2
  echo "--- body prefix ---" >&2
  head -c 120 "$body" >&2 || true
  echo >&2
  exit 1
fi

rm -f "$hdr" "$body"
log "embedded Wasmtime smoke test passed"
