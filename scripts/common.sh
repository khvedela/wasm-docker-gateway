#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$ROOT/results"
TS="$(date +"%Y%m%d_%H%M%S")"

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date +"%H:%M:%S")] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

start_upstream() {
  require_cmd docker
  (cd "$ROOT" && docker compose up -d upstream)
}

wait_http_200() {
  local url="$1"
  local tries="${2:-120}"
  local delay="${3:-0.05}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

# Best-effort RSS sampler (KB)
sample_rss_kb() {
  local pid="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ps -o rss= -p "$pid" | awk '{print $1}' || echo ""
  else
    if [[ -r "/proc/$pid/status" ]]; then
      awk '/VmRSS:/ {print $2}' "/proc/$pid/status" || echo ""
    else
      ps -o rss= -p "$pid" | awk '{print $1}' || echo ""
    fi
  fi
}
