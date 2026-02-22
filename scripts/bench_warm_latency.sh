#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd jq

PORT="${PORT:-18081}"

listener_pids_for_port() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u
    return 0
  fi

  if command -v fuser >/dev/null 2>&1; then
    fuser -n tcp "$port" 2>/dev/null \
      | tr ' ' '\n' \
      | grep -E '^[0-9]+$' \
      | sort -u
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltnpH 2>/dev/null \
      | awk -v p=":$port" '$4 ~ (p "$") {print}' \
      | grep -oE 'pid=[0-9]+' \
      | cut -d= -f2 \
      | sort -u
    return 0
  fi

  # Fallback for minimal Linux environments without lsof/fuser/ss:
  # discover listening socket inode from /proc/net/* and map inode -> PID via /proc/*/fd.
  if [[ -r /proc/net/tcp || -r /proc/net/tcp6 ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$port" <<'PY'
import glob
import os
import sys

port = int(sys.argv[1])
want = f"{port:04X}"
inodes = set()

for path in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        with open(path, "r", encoding="utf-8") as f:
            next(f, None)  # header
            for line in f:
                cols = line.split()
                if len(cols) < 10:
                    continue
                local = cols[1]
                state = cols[3]
                inode = cols[9]
                parts = local.split(":")
                if len(parts) != 2:
                    continue
                if state == "0A" and parts[1].upper() == want:
                    inodes.add(inode)
    except OSError:
        pass

if not inodes:
    raise SystemExit(0)

pids = set()
for fd in glob.glob("/proc/[0-9]*/fd/*"):
    try:
        link = os.readlink(fd)
    except OSError:
        continue
    if not link.startswith("socket:[") or not link.endswith("]"):
        continue
    inode = link[8:-1]
    if inode in inodes:
        pid = fd.split("/")[2]
        pids.add(pid)

for pid in sorted(pids, key=int):
    print(pid)
PY
    return 0
  fi
}

port_has_listener() {
  local port="$1"

  if listener_pids_for_port "$port" | grep -q .; then
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltnH 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {found=1; exit} END{exit !found}'; then
      return 0
    fi
  fi

  if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    return 0
  fi

  if (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
    exec 3>&-
    exec 3<&-
    return 0
  fi

  return 1
}

free_bench_port() {
  local port="$1"
  local -a pids=()
  local -a docker_ids=()

  # In some environments listener PID discovery is restricted; clear known
  # benchmark containers by name/port first so docker-proxy does not block us.
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "gateway-native-${port}" >/dev/null 2>&1 || true
    while IFS= read -r cid; do
      [[ -n "$cid" ]] && docker_ids+=("$cid")
    done < <(docker ps --format '{{.ID}} {{.Ports}}' 2>/dev/null | awk -v p=":${port}->" '$0 ~ p {print $1}')
    if (( ${#docker_ids[@]} > 0 )); then
      log "port :$port mapped by docker container(s): ${docker_ids[*]} — removing"
      docker rm -f "${docker_ids[@]}" >/dev/null 2>&1 || true
    fi
  fi

  while IFS= read -r p; do
    [[ -n "$p" ]] && pids+=("$p")
  done < <(listener_pids_for_port "$port" || true)

  if (( ${#pids[@]} > 0 )); then
    log "port :$port already in use by pid(s): ${pids[*]} — terminating stale listener(s)"
    kill -9 "${pids[@]}" >/dev/null 2>&1 || true
    for p in "${pids[@]}"; do
      wait "$p" 2>/dev/null || true
    done
  fi

  for _ in $(seq 1 100); do
    if ! port_has_listener "$port"; then
      return 0
    fi
    sleep 0.05
  done

  pids=()
  while IFS= read -r p; do
    [[ -n "$p" ]] && pids+=("$p")
  done < <(listener_pids_for_port "$port" || true)

  if (( ${#pids[@]} > 0 )); then
    echo "ERROR: port :$port is still in use after cleanup (pid(s): ${pids[*]})" >&2
  else
    echo "ERROR: port :$port is still in use after cleanup (could not resolve owner PID; install lsof/fuser/ss)" >&2
  fi
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

  if [[ "$variant" != "native_docker" ]]; then
    local listener_pid
    listener_pid="$(listener_pids_for_port "$PORT" | head -n1 || true)"
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
