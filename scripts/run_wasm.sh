#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose up -d upstream

# Load env vars from configs/wasm.env
set -a
source ./configs/wasm.env
set +a

# Build wasm module (we will implement code to support this)
cargo build --release --target wasm32-wasip1

# Run with WasmEdge
# WasmEdge provides socket networking via extensions; we’ll use that in the gateway. :contentReference[oaicite:0]{index=0}
wasmedge --env LISTEN="$LISTEN" --env UPSTREAM_URL="$UPSTREAM_URL" \
  target/wasm32-wasip1/release/gateway.wasm