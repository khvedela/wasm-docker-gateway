#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd hyperfine
require_cmd jq

PORT="${PORT:-18081}"
COLD_START_RUNS="${COLD_START_RUNS:-20}"
NATIVE_DOCKER_CONTAINER="gateway-native-${PORT}"

cd "$ROOT"
start_upstream
./scripts/build_wasm.sh

# Pre-build Rust binaries so hyperfine measures process startup, not compilation.
# On a fresh clone this can take minutes — do it once here, not inside the loop.
log "pre-building native binaries (cargo build --release) …"
cargo build --release --bin gateway_native --bin gateway_host

OUT="$RESULTS_DIR/cold_start_${TS}.csv"
echo "variant,run_ms" > "$OUT"

bench_one() {
  local variant="$1"
  local cmd="$2"
  local docker_cleanup="docker rm -f \"$NATIVE_DOCKER_CONTAINER\" >/dev/null 2>&1 || true"

  log "cold-start bench: $variant on :$PORT"
  local json="$RESULTS_DIR/tmp_${variant}_${TS}.json"

  hyperfine --warmup 0 --runs "$COLD_START_RUNS" --export-json "$json" \
    "bash -lc '
      set -euo pipefail
      ${docker_cleanup}
      ($cmd) >\"$RESULTS_DIR/${variant}_${TS}.log\" 2>&1 &
      pid=\$!
      for i in \$(seq 1 600); do
        curl -fsS --max-time 1 http://127.0.0.1:${PORT}/health >/dev/null 2>&1 && break
        sleep 0.01
      done
      curl -fsS --max-time 5 http://127.0.0.1:${PORT}/ >/dev/null
      kill -9 \$pid >/dev/null 2>&1 || true
      ${docker_cleanup}
    '"

  # hyperfine < 1.16 used "times"; >= 1.16 renamed it to "individual_times".
  # Support both with a fallback expression.
  local rows_before
  rows_before=$(wc -l < "$OUT")
  jq -r --arg variant "$variant" \
    '(.results[0].individual_times // .results[0].times)[] | "\($variant),\(. * 1000)"' \
    "$json" >> "$OUT"

  local nrows
  # Count only the rows added by this variant (lines now minus lines before jq ran)
  nrows=$(( $(wc -l < "$OUT") - rows_before ))
  log "  $variant: wrote $nrows rows to $(basename "$OUT")"

  if [[ "$variant" == "native_docker" ]]; then
    docker rm -f "$NATIVE_DOCKER_CONTAINER" >/dev/null 2>&1 || true
  fi
}

# Invoke the pre-built binaries directly rather than via `cargo run`.
# Even with a pre-built binary, `cargo run` adds ~200-500 ms of build-graph
# checking overhead — which would unfairly inflate native cold-start times
# compared to native_docker, which starts the binary directly with `docker run`.
bench_one "native_local" \
  "set -a; source \"$ROOT/configs/bench.env\"; set +a; exec \"$ROOT/target/release/gateway_native\""
bench_one "wasm_host_cli" \
  "set -a; source \"$ROOT/configs/bench.env\"; set +a; WASM_MODULE_PATH=\"$ROOT/gateway_logic.wasm\" exec \"$ROOT/target/release/gateway_host\""
bench_one "wasm_host_wasmtime" \
  "set -a; source \"$ROOT/configs/bench.env\"; set +a; WASM_RUNTIME=wasmtime WASM_MODULE_PATH=\"$ROOT/gateway_logic.wasm\" exec \"$ROOT/target/release/gateway_host\""
bench_one "wasm_host_wasmtime_embedded" \
  "set -a; source \"$ROOT/configs/bench.env\"; set +a; WASM_RUNTIME=wasmtime_embedded WASM_MODULE_PATH=\"$ROOT/gateway_logic.wasm\" exec \"$ROOT/target/release/gateway_host\""

# native_docker: pre-build the image once so the 20 hyperfine iterations only
# measure container startup time, not image build time.
log "pre-building gateway-native:dev for native_docker cold-start …"
if [[ -f "./target/release/gateway_native" ]]; then
  docker build -q -t gateway-native:dev -f ./gateway_native/Dockerfile.prebuilt . >&2
else
  docker build -q -t gateway-native:dev -f ./gateway_native/Dockerfile . >&2
fi
bench_one "native_docker" "SKIP_BUILD=1 PORT=$PORT ./scripts/run_docker.sh"

log "wrote $OUT"
