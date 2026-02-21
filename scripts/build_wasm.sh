#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"

# Ensure WASI target exists
rustup target add wasm32-wasip1 >/dev/null 2>&1 || rustup target add wasm32-wasi >/dev/null 2>&1 || true

TARGET="wasm32-wasip1"
if ! rustc --print target-list | grep -q "^wasm32-wasip1$"; then
  TARGET="wasm32-wasi"
fi

echo "[build_wasm] building gateway_wasm for $TARGET"
cargo build -p gateway_wasm --release --target "$TARGET"

cp "target/$TARGET/release/gateway_wasm.wasm" "$ROOT/gateway_logic.wasm"
echo "[build_wasm] wrote $ROOT/gateway_logic.wasm"
