#!/usr/bin/env bash
# run_docker.sh — run gateway_native inside Docker for benchmarking.
#
# Usage:
#   PORT=18081 ./scripts/run_docker.sh
#
# The container always binds gateway on 0.0.0.0:8080 internally.  The host-side
# port is controlled by PORT (default 18081) via -p ${PORT}:8080.
#
# Upstream discovery:
#   We detect the Docker network that the compose 'upstream' service is on so the
#   container can resolve the hostname "upstream" directly, avoiding the need for
#   host.docker.internal (which is unreliable on Linux VMs).
#
# Cleanup:
#   Any container with the same name is removed before starting.
#   The container itself runs with --rm so it is removed when killed.
#   bench_throughput.sh terminates us via kill -9 on the docker-run PID, which
#   stops the container (Docker propagates SIGKILL to the container process).

set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-18081}"
CONTAINER_INNER_PORT=8080        # gateway always listens on this inside the container
CONTAINER_NAME="gateway-native-${PORT}"
IMAGE="gateway-native:dev"

# ---------------------------------------------------------------------------
# 1. Build image (skip with SKIP_BUILD=1, e.g. from cold-start bench)
# ---------------------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  # Prefer the fast prebuilt path when the binary already exists on the host.
  # Falls back to full source compile (Dockerfile) if binary is missing.
  if [[ -f "./target/release/gateway_native" ]]; then
    echo "[run_docker] pre-built binary found — using Dockerfile.prebuilt (fast)" >&2
    docker build -t "$IMAGE" -f ./gateway_native/Dockerfile.prebuilt . >&2
  else
    echo "[run_docker] no pre-built binary — building from source (slow first run)" >&2
    docker build -t "$IMAGE" -f ./gateway_native/Dockerfile . >&2
  fi
else
  echo "[run_docker] SKIP_BUILD=1 — reusing existing image $IMAGE" >&2
fi

# ---------------------------------------------------------------------------
# 2. Detect which Docker network the compose 'upstream' container is on.
#    We want a network that the gateway container can join so it can reach
#    the 'upstream' service by DNS name rather than by host IP.
# ---------------------------------------------------------------------------
COMPOSE_NETWORK=""
UPSTREAM_CID="$(docker compose ps -q upstream 2>/dev/null | head -n1 || true)"
if [[ -n "$UPSTREAM_CID" ]]; then
  # List all networks attached to the upstream container; skip the default
  # "bridge" network (no DNS resolution between containers there).
  COMPOSE_NETWORK="$(
    docker inspect "$UPSTREAM_CID" \
      --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
      2>/dev/null \
    | grep -v '^bridge$' \
    | grep -v '^$' \
    | head -n1 \
    || true
  )"
fi

if [[ -z "$COMPOSE_NETWORK" ]]; then
  # Fallback: compose default network is <project-dir-basename>_default
  COMPOSE_NETWORK="$(basename "$(pwd)")_default"
  echo "[run_docker] upstream container not found or network not detected; assuming network: $COMPOSE_NETWORK" >&2
else
  echo "[run_docker] joining compose network: $COMPOSE_NETWORK" >&2
fi

UPSTREAM_URL="http://upstream:18080"

# ---------------------------------------------------------------------------
# 3. Remove any leftover container with the same name
# ---------------------------------------------------------------------------
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "[run_docker] removing leftover container $CONTAINER_NAME …" >&2
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 4. Run in the foreground.
#    bench_throughput.sh starts this script as a background job and kills the
#    shell PID.  Docker propagates the signal to the container so --rm cleans up.
# ---------------------------------------------------------------------------
echo "[run_docker] starting $CONTAINER_NAME on host port $PORT (container :$CONTAINER_INNER_PORT) …" >&2
exec docker run --rm \
  --name "$CONTAINER_NAME" \
  --network "$COMPOSE_NETWORK" \
  -p "${PORT}:${CONTAINER_INNER_PORT}" \
  -e "LISTEN=0.0.0.0:${CONTAINER_INNER_PORT}" \
  -e "UPSTREAM_URL=${UPSTREAM_URL}" \
  "$IMAGE"
