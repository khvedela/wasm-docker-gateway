#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

set -a
source ./configs/bench.env
set +a

exec cargo run -p gateway_native --release
