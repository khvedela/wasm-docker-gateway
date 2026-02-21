#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd wrk

log "Running all benchmarks (port 18081)..."
./scripts/bench_cold_start.sh
./scripts/bench_warm_latency.sh
./scripts/bench_throughput.sh
log "All done. See results/."
