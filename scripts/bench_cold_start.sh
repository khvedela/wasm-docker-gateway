#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd jq

PORT="${PORT:-18081}"
COLD_START_RUNS="${COLD_START_RUNS:-20}"

cd "$ROOT"
start_upstream
./scripts/build_wasm.sh

OUT="$RESULTS_DIR/cold_start_${TS}.csv"
echo "variant,run_ms" > "$OUT"

bench_one() {
  local variant="$1"
  local cmd="$2"

  log "cold-start bench: $variant on :$PORT"
  local json="$RESULTS_DIR/tmp_${variant}_${TS}.json"

  hyperfine --warmup 0 --runs "$COLD_START_RUNS" --export-json "$json" \
    "bash -lc '
      set -euo pipefail
      ($cmd) >\"$RESULTS_DIR/${variant}_${TS}.log\" 2>&1 &
      pid=\$!
      for i in \$(seq 1 200); do
        curl -fsS --max-time 1 http://127.0.0.1:${PORT}/health >/dev/null 2>&1 && break
        sleep 0.01
      done
      curl -fsS --max-time 5 http://127.0.0.1:${PORT}/ >/dev/null
      kill -9 \$pid >/dev/null 2>&1 || true
    '"

  jq -r --arg variant "$variant" \
    '.results[0].times[] | "\($variant),\(. * 1000)"' \
    "$json" >> "$OUT"
}

bench_one "native_local"  "./scripts/run_native_local.sh"
bench_one "wasm_host_cli" "WASM_MODULE_PATH=$ROOT/gateway_logic.wasm ./scripts/run_wasm_host_local.sh"

# native_docker: pre-build the image once so the 20 hyperfine iterations only
# measure container startup time, not image build time.
log "pre-building gateway-native:dev for native_docker cold-start …"
docker build -q -t gateway-native:dev -f ./gateway_native/Dockerfile . >&2
bench_one "native_docker" "SKIP_BUILD=1 PORT=$PORT ./scripts/run_docker.sh"

log "wrote $OUT"
