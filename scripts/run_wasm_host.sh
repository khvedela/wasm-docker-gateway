#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose up -d upstream

set -a
source ./configs/wasm.env
set +a

# Build wasm module
rustup target add wasm32-wasip1 >/dev/null 2>&1 || rustup target add wasm32-wasi >/dev/null 2>&1

# Prefer wasm32-wasip1 if available
TARGET="wasm32-wasip1"
if ! rustc --print target-list | grep -q "^wasm32-wasip1$"; then
  TARGET="wasm32-wasi"
fi

cargo build -p gateway_wasm --release --target "$TARGET"

cp "target/$TARGET/release/gateway_wasm.wasm" ./gateway_logic.wasm

# Run host
export WASM_MODULE_PATH="$(pwd)/gateway_logic.wasm"
cargo run -p gateway_host --release