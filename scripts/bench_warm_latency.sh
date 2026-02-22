#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd jq

PORT="${PORT:-18081}"

free_bench_port() {
  local port="$1"
  local -a pids=()

  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && pids+=("$p")
    done < <(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u)
  elif command -v fuser >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && pids+=("$p")
    done < <(fuser -n tcp "$port" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)
  fi

  if (( ${#pids[@]} > 0 )); then
    log "port :$port already in use by pid(s): ${pids[*]} — terminating stale listener(s)"
    kill -9 "${pids[@]}" >/dev/null 2>&1 || true
    for p in "${pids[@]}"; do
      wait "$p" 2>/dev/null || true
    done
  fi

  for _ in $(seq 1 100); do
    local still_busy=""
    if command -v lsof >/dev/null 2>&1; then
      still_busy="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true)"
    elif command -v fuser >/dev/null 2>&1; then
      still_busy="$(fuser -n tcp "$port" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | head -n1 || true)"
    fi
    [[ -z "$still_busy" ]] && return 0
    sleep 0.05
  done

  echo "ERROR: port :$port is still in use after cleanup" >&2
  return 1
}

cd "$ROOT"
start_upstream
./scripts/build_wasm.sh

log "pre-building native binaries (cargo build --release) …"
cargo build --release --bin gateway_native --bin gateway_host

OUT="$RESULTS_DIR/warm_latency_${TS}.csv"
echo "variant,run_ms" > "$OUT"

run_server_and_bench() {
  local variant="$1"
  local cmd="$2"
  local pid=""
  local container_name="gateway-native-${PORT}"

  cleanup_variant() {
    if [[ "$variant" == "native_docker" ]]; then
      docker rm -f "$container_name" >/dev/null 2>&1 || true
    fi

    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.1
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
    fi

    free_bench_port "$PORT" || true
  }

  free_bench_port "$PORT"
  log "starting $variant on :$PORT"
  bash -lc "$cmd" >"$RESULTS_DIR/${variant}_warm_${TS}.log" 2>&1 &
  pid=$!

  # Always clean up the server, even if hyperfine fails
  trap cleanup_variant EXIT INT TERM

  if ! wait_http_200 "http://127.0.0.1:${PORT}/health" 200 0.01; then
    tail -n 120 "$RESULTS_DIR/${variant}_warm_${TS}.log" || true
    exit 1
  fi

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "ERROR: launched PID $pid for $variant is not alive after health check" >&2
    tail -n 120 "$RESULTS_DIR/${variant}_warm_${TS}.log" || true
    exit 1
  fi

  if [[ "$variant" != "native_docker" ]] && command -v lsof >/dev/null 2>&1; then
    local listener_pid
    listener_pid="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true)"
    if [[ -n "$listener_pid" && "$listener_pid" != "$pid" ]]; then
      echo "ERROR: health endpoint is not served by launched PID (expected $pid, listener $listener_pid)" >&2
      tail -n 120 "$RESULTS_DIR/${variant}_warm_${TS}.log" || true
      exit 1
    fi
  fi

  log "benchmarking warm latency for $variant (warmup=20 runs=300)"
  local json="$RESULTS_DIR/tmp_warm_${variant}_${TS}.json"

  hyperfine --warmup 20 --runs 300 --ignore-failure --export-json "$json" \
    "curl -fsS --max-time 5 http://127.0.0.1:${PORT}/ >/dev/null"

  jq -r --arg variant "$variant" \
    '(.results[0].individual_times // .results[0].times)[] | "\($variant),\(. * 1000)"' \
    "$json" >> "$OUT"

  cleanup_variant
  trap - EXIT INT TERM
}

run_server_and_bench "native_local"  "./scripts/run_native_local.sh"
run_server_and_bench "native_docker" "PORT=$PORT ./scripts/run_docker.sh"
run_server_and_bench "wasm_host_cli" "WASM_MODULE_PATH=$ROOT/gateway_logic.wasm ./scripts/run_wasm_host_local.sh"
run_server_and_bench "wasm_host_wasmtime" "PORT=$PORT WASM_MODULE_PATH=$ROOT/gateway_logic.wasm ./scripts/run_wasm_host_wasmtime.sh"

log "wrote $OUT"
