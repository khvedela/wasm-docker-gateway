#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd wrk
require_cmd awk

# You can override these via env vars
DURATION="${DURATION:-20s}"
THREADS="${THREADS:-4}"
# Scalability: either provide CONNS_LIST (comma-separated) or a single CONNS value.
# If neither is set, defaults to the 4-level list below.
CONNS_LIST="${CONNS_LIST:-}"             # highest priority: explicit comma list
CONNS_DEFAULT="${CONNS:-10,50,100,200}"  # fallback: single value or default 4-level list
PORT="${PORT:-18081}"

cd "$ROOT"

# Detect a hard-timeout wrapper (GNU timeout or macOS coreutils gtimeout).
# Used to prevent wrk from hanging indefinitely on a stalled server.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout"
fi

start_upstream
./scripts/build_wasm.sh

log "pre-building native binaries (cargo build --release) …"
cargo build --release --bin gateway_native --bin gateway_host

# Aggregated CSV — written fresh each run so stale data from prior runs
# never pollutes averages.  Set APPEND_RESULTS=1 to accumulate across runs.
AGG_DIR="$RESULTS_DIR/aggregated"
mkdir -p "$AGG_DIR"
SUM="$AGG_DIR/throughput.csv"

if [[ "${APPEND_RESULTS:-0}" == "1" && -f "$SUM" ]]; then
  log "APPEND_RESULTS=1 — appending to existing $SUM"
else
  [[ -f "$SUM" ]] && log "truncating previous $SUM (set APPEND_RESULTS=1 to keep)"
  echo "run_ts,variant,workload,threads,conns,duration_s,rps,latency_mean_ms,gateway_rss_avg_kb,gateway_rss_max_kb,gateway_cpu_avg,gateway_cpu_max,wasmedge_rss_avg_kb,wasmedge_rss_max_kb,wasmedge_cpu_avg,wasmedge_cpu_max" > "$SUM"
fi

# --- Helpers ---

ts_ms() {
  # GNU date supports %3N (milliseconds); macOS date does not — fall back to python3.
  local t
  t="$(date +%s%3N 2>/dev/null)"
  if [[ "$t" =~ ^[0-9]{10,}$ ]]; then
    printf '%s\n' "$t"
  else
    python3 -c 'import time; print(int(time.time()*1000))'
  fi
}

duration_to_seconds() {
  local d="$1"
  if [[ "$d" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$d" =~ ^([0-9]+)m$ ]]; then
    echo "$(( ${BASH_REMATCH[1]} * 60 ))"
  else
    # fall back (treat as seconds)
    echo "$d"
  fi
}

# Resolve Python interpreter — prefer the project venv if present.
PYTHON=""
for _py in "$ROOT/.venv/bin/python3" "$ROOT/.venv/bin/python" python3 python; do
  if command -v "$_py" >/dev/null 2>&1; then PYTHON="$_py"; break; fi
done
[[ -n "$PYTHON" ]] || { echo "ERROR: no python3 found" >&2; exit 1; }

# Ensure psutil is available; install it into the venv if missing.
if ! "$PYTHON" -c "import psutil" 2>/dev/null; then
  log "psutil not found — installing …"
  "$PYTHON" -m pip install psutil || { echo "ERROR: failed to install psutil" >&2; exit 1; }
fi

SAMPLER="$ROOT/scripts/sampler.py"

# _sampler_loop: exec sampler.py — called with & at the call site so $! = Python PID.
# Args: mode pid out [sample_pid]
_sampler_loop() {
  local mode="$1" pid="$2" out="$3" sample_pid="${4:-$2}"
  exec "$PYTHON" "$SAMPLER" \
    --mode "$mode" \
    --pid "$pid" \
    --sample-pid "$sample_pid" \
    --out "$out" \
    --interval 0.2
}


# Aggregate sampler CSV -> avg_rss,max_rss,avg_cpu,max_cpu
agg_samples() {
  local in="$1"
  awk -F',' '
    NR==1{next}
    {
      rss=$2+0; cpu=$3+0;
      rss_sum+=rss; cpu_sum+=cpu; n+=1;
      if(rss>rss_max) rss_max=rss;
      if(cpu>cpu_max) cpu_max=cpu;
    }
    END{
      if(n==0){print "0,0,0,0"; exit}
      printf "%.2f,%d,%.2f,%.2f\n", rss_sum/n, rss_max, cpu_sum/n, cpu_max
    }
  ' "$in"
}

# Parse wrk output (rps + mean latency in ms)
parse_wrk() {
  local raw="$1"
  local rps lat val unit

  rps="$(grep -E 'Requests/sec:' "$raw" | awk '{print $2}' | head -n1 || true)"

  # wrk prints latency like: "Latency   10.23ms   2.34ms ..." or "Latency  1.23s ..."
  # Extract the 2nd token after "Latency"
  lat="$(grep -E '^\s*Latency' "$raw" | awk '{print $2}' | head -n1 || true)"

  # Convert to milliseconds (best-effort)
  if [[ "$lat" =~ ^([0-9.]+)(us|ms|s)$ ]]; then
    val="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
      us) lat_ms="$(awk -v v="$val" 'BEGIN{printf "%.3f", v/1000.0}')" ;;
      ms) lat_ms="$(awk -v v="$val" 'BEGIN{printf "%.3f", v}')" ;;
      s)  lat_ms="$(awk -v v="$val" 'BEGIN{printf "%.3f", v*1000.0}')" ;;
    esac
  else
    lat_ms=""
  fi

  echo "$rps,$lat_ms"
}

# Workload URLs
url_for_workload() {
  local workload="$1"
  case "$workload" in
    hello)  echo "http://127.0.0.1:${PORT}/" ;;
    compute) echo "http://127.0.0.1:${PORT}/compute?iters=20000" ;;
    state)  echo "http://127.0.0.1:${PORT}/state" ;;
    proxy)  echo "http://127.0.0.1:${PORT}/foo" ;; # non-special path => proxy
    *)      echo "http://127.0.0.1:${PORT}/" ;;
  esac
}

bench_variant() {
  local variant="$1"
  local cmd="$2"

  log "starting $variant on :$PORT"
  local server_log
  server_log="$RESULTS_DIR/${variant}_server_$(date +%Y%m%d_%H%M%S).log"
  bash -lc "$cmd" >"$server_log" 2>&1 &
  local pid=$!

  # Ensure we always clean up on exit/interrupt
  sampler_gw_pid=""
  sampler_we_pid=""
  cleanup_variant() {
    # best-effort: stop samplers then server
    [[ -n "${sampler_gw_pid}" ]] && kill "${sampler_gw_pid}" >/dev/null 2>&1 || true
    [[ -n "${sampler_we_pid}" ]] && kill "${sampler_we_pid}" >/dev/null 2>&1 || true
    kill -9 "$pid" >/dev/null 2>&1 || true
  }
  trap cleanup_variant EXIT INT TERM

  if ! wait_http_200 "http://127.0.0.1:${PORT}/health" 200 0.01; then
    tail -n 160 "$server_log" || true
    kill -9 "$pid" >/dev/null 2>&1 || true
    exit 1
  fi

  # Determine which connection levels to run
  local conns_list="${CONNS_LIST:-$CONNS_DEFAULT}"

  local -a CONNS_ARR
  IFS=',' read -r -a CONNS_ARR <<< "$conns_list"

  local duration_s
  duration_s="$(duration_to_seconds "$DURATION")"

  # ---- Progress tracking ----
  local -a workloads=(hello compute state proxy)
  local total_runs=$(( ${#CONNS_ARR[@]} * ${#workloads[@]} ))
  local run_index=0
  local expected_secs=$(( total_runs * (duration_s + 5) ))
  local expected_min=$(( expected_secs / 60 ))
  local expected_sec=$(( expected_secs % 60 ))
  log "=== $variant: $total_runs runs planned, expected ~${expected_min}m${expected_sec}s (${duration_s}s/run + ~5s overhead each) ==="

  for workload in "${workloads[@]}"; do
    local url
    url="$(url_for_workload "$workload")"

    # Small warmup to reduce first-run artifacts (no logging, ignore failures)
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 || true

    for conns in "${CONNS_ARR[@]}"; do
      local run_ts
      run_ts="$(ts_ms)"

      run_index=$((run_index+1))
      local eta_epoch=$(( $(date +%s) + duration_s + 3 ))
      local eta_str
      eta_str="$(date -r "$eta_epoch" +"%H:%M:%S" 2>/dev/null \
               || date -d "@$eta_epoch" +"%H:%M:%S" 2>/dev/null \
               || echo "?")"
      printf '[%s] %02d/%02d workload=%-8s conns=%-4s threads=%s duration=%s ETA=%s\n' \
        "$variant" "$run_index" "$total_runs" "$workload" "$conns" "$THREADS" "$DURATION" "$eta_str"

      local raw
      raw="$RESULTS_DIR/wrk_${variant}_${workload}_${conns}_$(date +%Y%m%d_%H%M%S).txt"

      # Start samplers directly with & so $! is the real loop PID — no command substitution.
      local gw_samples we_samples
      gw_samples="$RESULTS_DIR/samples_${variant}_${workload}_${conns}_gw.csv"
      we_samples="$RESULTS_DIR/samples_${variant}_${workload}_${conns}_we.csv"

      # For native_docker: $pid is the 'docker run' CLI (tiny RSS, 0 CPU).
      # Get the container's real host PID so the sampler measures the gateway process.
      local gw_sample_pid="$pid"
      if [[ "$variant" == "native_docker" ]]; then
        local container_name="gateway-native-${PORT}"
        local cpid
        cpid="$(docker inspect --format '{{.State.Pid}}' "$container_name" 2>/dev/null || true)"
        [[ "$cpid" =~ ^[0-9]+$ && "$cpid" != "0" ]] && gw_sample_pid="$cpid"
      fi

      _sampler_loop gateway "$pid" "$gw_samples" "$gw_sample_pid" &
      sampler_gw_pid=$!
      _sampler_loop wasmedge "$pid" "$we_samples" &
      sampler_we_pid=$!

      # Brief pause then verify samplers are alive (diagnose silent failures)
      sleep 0.3
      kill -0 "$sampler_gw_pid" 2>/dev/null \
        || log "  WARN: gateway sampler (pid=$sampler_gw_pid) exited early — rss/cpu will be 0"
      # Run wrk with a hard timeout (duration + 30s cushion) to prevent hangs
      local wrk_timeout=$(( duration_s + 30 ))
      if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$wrk_timeout" wrk -t"$THREADS" -c"$conns" -d"$DURATION" "$url" | tee "$raw" >/dev/null
      else
        wrk -t"$THREADS" -c"$conns" -d"$DURATION" "$url" | tee "$raw" >/dev/null
      fi

      # Stop samplers and wait for them to flush writes before reading CSVs
      kill "$sampler_gw_pid" >/dev/null 2>&1 || true
      kill "$sampler_we_pid" >/dev/null 2>&1 || true
      wait "$sampler_gw_pid" 2>/dev/null || true
      wait "$sampler_we_pid" 2>/dev/null || true

      # Parse wrk stats
      local parsed rps lat_ms
      parsed="$(parse_wrk "$raw")"
      rps="${parsed%,*}"
      lat_ms="${parsed#*,}"

      # Aggregate samples
      local gw_agg we_agg
      gw_agg="$(agg_samples "$gw_samples")" # avg_rss,max_rss,avg_cpu,max_cpu
      we_agg="$(agg_samples "$we_samples")"

      local gw_rss_avg gw_rss_max gw_cpu_avg gw_cpu_max
      local we_rss_avg we_rss_max we_cpu_avg we_cpu_max

      IFS=',' read -r gw_rss_avg gw_rss_max gw_cpu_avg gw_cpu_max <<< "$gw_agg"
      IFS=',' read -r we_rss_avg we_rss_max we_cpu_avg we_cpu_max <<< "$we_agg"

      log "  -> rps=${rps} latency_mean_ms=${lat_ms} gw_rss_avg_kb=${gw_rss_avg} gw_cpu_avg=${gw_cpu_avg}%"
      echo "${run_ts},${variant},${workload},${THREADS},${conns},${duration_s},${rps},${lat_ms},${gw_rss_avg},${gw_rss_max},${gw_cpu_avg},${gw_cpu_max},${we_rss_avg},${we_rss_max},${we_cpu_avg},${we_cpu_max}" >> "$SUM"
    done
  done

  log "completed all runs for $variant"
  cleanup_variant
  trap - EXIT INT TERM
  log "appended aggregated results to $SUM"
}

# Invoke pre-built binaries directly (not via cargo run) so that $pid in
# bench_variant is the actual gateway process, not an intermediate cargo/shell
# wrapper.  Cargo forks the binary as a child and blocks in wait(); after the
# first wrk run cargo has near-zero RSS, making all subsequent memory samples
# read 0.  Directly exec-ing the binary avoids this entirely.
bench_variant "native_local" \
  "set -a; source \"$ROOT/configs/bench.env\"; set +a
   exec \"$ROOT/target/release/gateway_native\""
bench_variant "native_docker" "PORT=$PORT ./scripts/run_docker.sh"
bench_variant "wasm_host_cli" \
  "set -a; source \"$ROOT/configs/bench.env\"; set +a
   WASM_MODULE_PATH=\"$ROOT/gateway_logic.wasm\" exec \"$ROOT/target/release/gateway_host\""

# ---------------------------------------------------------------------------
# ANALYSIS CSV
#
# Why wasmedge_* columns are N/A for wasm_host_cli:
#   In the wasm_host_cli variant the Rust host spawns `wasmedge` as a
#   short-lived subprocess *per request* (lifetime ≈ a few milliseconds).
#   The sampler polls every ~200 ms, so it almost never catches a running
#   wasmedge process. The columns read as zeros by chance, not by design.
#
# Why totals are still valid for wasm_host_cli:
#   The gateway_host process blocks synchronously (stdio pipe) while waiting
#   for wasmedge to exit, so gateway RSS / CPU already account for the full
#   cost of each request (execution time, wait time, process-spawn overhead).
#   RPS and latency_mean_ms likewise capture the true end-to-end cost.
#
# For native_local and native_docker: totals == gateway values (single process).
# ---------------------------------------------------------------------------
log "generating throughput_analysis.csv …"
ANALYSIS="$AGG_DIR/throughput_analysis.csv"
python3 - "$SUM" "$ANALYSIS" <<'PY'
import sys, csv

src, dst = sys.argv[1], sys.argv[2]

# Variants whose wasmedge_* columns cannot be reliably sampled.
WASM_VARIANTS = {"wasm_host_cli"}
NA = "NA"

with open(src, newline="") as f:
    reader = csv.DictReader(f)
    fieldnames = list(reader.fieldnames) + [
        "total_rss_avg_kb", "total_rss_max_kb",
        "total_cpu_avg",    "total_cpu_max",
    ]
    rows = list(reader)

with open(dst, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        v = row["variant"]
        if v in WASM_VARIANTS:
            # Sampler cannot reliably capture per-request short-lived processes.
            row["wasmedge_rss_avg_kb"] = NA
            row["wasmedge_rss_max_kb"] = NA
            row["wasmedge_cpu_avg"]    = NA
            row["wasmedge_cpu_max"]    = NA
        # Totals: gateway values only.
        # For native_local / native_docker: gateway IS the whole process.
        # For wasm_host_cli: gateway blocks on wasmedge stdio, so its RSS/CPU
        # already capture the full per-request cost.
        def _f(col):
            try: return float(row[col])
            except: return 0.0
        row["total_rss_avg_kb"] = f"{_f('gateway_rss_avg_kb'):.2f}"
        row["total_rss_max_kb"] = f"{_f('gateway_rss_max_kb'):.2f}"
        row["total_cpu_avg"]    = f"{_f('gateway_cpu_avg'):.2f}"
        row["total_cpu_max"]    = f"{_f('gateway_cpu_max'):.2f}"
        writer.writerow(row)

print(f"wrote {len(rows)} rows -> {dst}")
PY
log "analysis CSV: $ANALYSIS"
