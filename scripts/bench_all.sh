#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd wrk
require_cmd nproc
require_cmd free

PORT="${PORT:-18081}"
CONNS_LIST="${CONNS_LIST:-10,50,100,200,400,800,1200}"
DURATION="${DURATION:-30s}"
REPEATS="${REPEATS:-3}"
RESET_RESULTS="${RESET_RESULTS:-1}"

export PORT

log "=== Benchmark Suite Start ==="
log "PORT=$PORT"
log "CONNS_LIST=$CONNS_LIST"
log "DURATION=$DURATION"
log "REPEATS=$REPEATS"

mkdir -p results/meta
{
  echo "timestamp: $(date -Iseconds)"
  echo "kernel: $(uname -a)"
  echo "cpu_cores: $(nproc)"
  echo "memory:"
  free -h
  echo "rustc: $(rustc --version 2>/dev/null || true)"
  echo "wrk: $(wrk --version 2>/dev/null || true)"
  echo "hyperfine: $(hyperfine --version 2>/dev/null || true)"
  echo "git_commit: $(git rev-parse HEAD 2>/dev/null || true)"
} > "results/meta/env_snapshot_$(date +%Y%m%d_%H%M%S).txt"

if [[ "$RESET_RESULTS" == "1" ]]; then
  log "Resetting previous aggregated results..."
  rm -f results/aggregated/*.csv || true
fi

log "Running cold start ($REPEATS repetitions)..."
for i in $(seq 1 "$REPEATS"); do
  log "Cold start run $i/$REPEATS"
  APPEND_RESULTS=1 ./scripts/bench_cold_start.sh
done

log "Running warm latency ($REPEATS repetitions)..."
for i in $(seq 1 "$REPEATS"); do
  log "Warm latency run $i/$REPEATS"
  APPEND_RESULTS=1 ./scripts/bench_warm_latency.sh
done

log "Running throughput ($REPEATS repetitions)..."
for i in $(seq 1 "$REPEATS"); do
  log "Throughput run $i/$REPEATS"
  if [[ "$i" == "1" && "$RESET_RESULTS" == "1" ]]; then
    APPEND_RESULTS=0 CONNS_LIST="$CONNS_LIST" DURATION="$DURATION" ./scripts/bench_throughput.sh
  else
    APPEND_RESULTS=1 CONNS_LIST="$CONNS_LIST" DURATION="$DURATION" ./scripts/bench_throughput.sh
  fi
done

log "=== Benchmark Suite Complete ==="
log "Results available under results/"