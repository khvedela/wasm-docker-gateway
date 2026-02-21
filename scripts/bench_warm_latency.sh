#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd jq

PORT="${PORT:-18081}"

cd "$ROOT"
start_upstream
./scripts/build_wasm.sh

OUT="$RESULTS_DIR/warm_latency_${TS}.csv"
echo "variant,run_ms" > "$OUT"

run_server_and_bench() {
  local variant="$1"
  local cmd="$2"
  local pid=""

  log "starting $variant on :$PORT"
  bash -lc "$cmd" >"$RESULTS_DIR/${variant}_warm_${TS}.log" 2>&1 &
  pid=$!

  # Always clean up the server, even if hyperfine fails
  trap 'kill -9 "$pid" >/dev/null 2>&1 || true' EXIT INT TERM

  if ! wait_http_200 "http://127.0.0.1:${PORT}/health" 200 0.01; then
    tail -n 120 "$RESULTS_DIR/${variant}_warm_${TS}.log" || true
    exit 1
  fi

  log "benchmarking warm latency for $variant (warmup=20 runs=300)"
  local json="$RESULTS_DIR/tmp_warm_${variant}_${TS}.json"

  hyperfine --warmup 20 --runs 300 --export-json "$json" \
    "curl -fsS --max-time 5 http://127.0.0.1:${PORT}/ >/dev/null"

  jq -r --arg variant "$variant" \
    '.results[0].times[] | "\($variant),\(. * 1000)"' \
    "$json" >> "$OUT"

  kill -9 "$pid" >/dev/null 2>&1 || true
  trap - EXIT INT TERM
}

run_server_and_bench "native_local"  "./scripts/run_native_local.sh"
run_server_and_bench "native_docker" "PORT=$PORT ./scripts/run_docker.sh"
run_server_and_bench "wasm_host_cli" "WASM_MODULE_PATH=$ROOT/gateway_logic.wasm ./scripts/run_wasm_host_local.sh"

log "wrote $OUT"
