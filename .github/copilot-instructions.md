# Project Guidelines

## Architecture

A Rust workspace benchmarking **WASM-hosted** vs **native** gateway middleware:

- **`gateway_native/`** — single-threaded TCP gateway in pure Rust; handles `hello`, `compute`, `state`, and `proxy` workloads; reads config via `LISTEN` / `UPSTREAM_URL` env vars.
- **`gateway_host/`** — same TCP gateway, but delegates per-request logic to `gateway_wasm.wasm` by spawning a `wasmedge` CLI subprocess. Communicates via stdio (HTTP request bytes → stdin, response bytes ← stdout). Needs `WASM_MODULE_PATH` env var.
- **`gateway_wasm/`** — pure WASM module (`wasm32-wasip1` target, no_std-compatible, zero deps); receives request on stdin, writes response to stdout.
- **`docker-compose.yml`** — brings up a `hashicorp/http-echo` upstream on port 18080 used by both gateway variants.

Data flow: `wrk` → gateway (`:18081`) → upstream (`:18080`). Results appended to `results/aggregated/throughput.csv`.

## Build and Test

```bash
# Build all native binaries
cargo build --release

# Build WASM module → gateway_logic.wasm (required before running wasm_host variant)
./scripts/build_wasm.sh

# Start upstream dependency (Docker required)
docker compose up -d upstream

# Run native gateway locally (loads configs/bench.env)
./scripts/run_native_local.sh

# Run WASM-host gateway locally
./scripts/run_wasm_host_local.sh

# Full benchmark suite (requires wrk, hyperfine, curl)
./scripts/bench_all.sh

# Individual benchmarks
./scripts/bench_throughput.sh
./scripts/bench_cold_start.sh
./scripts/bench_warm_latency.sh
```

Benchmark results land in `results/` (per-run `.csv` and `.txt`) and are aggregated into `results/aggregated/throughput.csv`.

## Benchmark Reproducibility

**Cold-start** ([scripts/bench_cold_start.sh](../scripts/bench_cold_start.sh)):

- Tool: `hyperfine --warmup 0 --runs 20`
- No filesystem or process cache warming — measures fresh startup each run
- Each run spawns the gateway, polls `http://127.0.0.1:18081/health` (up to 2 s, 10 ms intervals), fires one request, then `kill -9`s the process
- Output: `results/cold_start_{TS}.csv` (variant, run*ms), per-variant log `results/{variant}*{TS}.log`

**Warm-latency** ([scripts/bench_warm_latency.sh](../scripts/bench_warm_latency.sh)):

- Tool: `hyperfine --warmup 20 --runs 300`
- Server started once and kept alive; `kill -9` after all runs complete
- Measures `curl` round-trip to `http://127.0.0.1:18081/`
- Output: `results/warm_latency_{TS}.csv` (variant, run_ms)

**Throughput** ([scripts/bench_throughput.sh](../scripts/bench_throughput.sh)):

- Tool: `wrk`, default 4 threads, configurable connection counts (default `10,50,100,200`) and duration (`DURATION=20s`)
- Output: per-run `results/wrk_{variant}_{workload}_{conns}_{TS}.txt` + `results/aggregated/throughput.csv`

All three scripts use **port 18081** exclusively, kill processes cleanly with `kill -9`, and write to timestamped files — state is not reused across runs.

**Machine specs are not captured automatically.** When comparing results, record CPU model, core count, RAM, and OS manually.

## Docker Deployment

- `configs/docker.env`: sets `UPSTREAM_URL=http://host.docker.internal:18080` for gateway containers reaching the host-side upstream.
- Three tested deployment modes: native binary on host, native binary in container (`gateway_native/Dockerfile`), WASM-host on host (`gateway_host/Dockerfile`).
- No multi-service orchestration beyond the single `upstream` service in `docker-compose.yml`.

## Code Style

Rust edition 2021, `anyhow` for error propagation, `env_logger` for logging. Use `anyhow::Context` (`.with_context(|| ...)`) on fallible calls. Stderr for operational logs (`eprintln!("[tag] ...")`), stdout reserved for response data in the WASM module.

## Project Conventions

- **Variants**: rows in CSVs use `variant` values `native_local` or `wasm_host_cli`.
- **Workloads**: `hello` (no-op), `compute` (SHA-256 chain, param `?iters=N`), `state` (atomic counter), `proxy` (forward to upstream).
- **Config files**: `configs/bench.env` (local benchmark ports), `configs/wasm.env` / `configs/docker.env` (alternate deployment configs). Scripts source these with `set -a; source ./configs/bench.env; set +a`.
- **WASM target**: prefer `wasm32-wasip1`; fall back to `wasm32-wasi` if unavailable (see [build_wasm.sh](../scripts/build_wasm.sh)).
- **No Tokio / async** in any gateway crate — all I/O is blocking with `TcpStream` and `set_read_timeout` / `set_write_timeout`.

## Integration Points

- **Upstream**: `docker compose up -d upstream` must be running before any gateway or benchmark script.
- **wasmedge CLI**: must be on `$PATH` for `gateway_host` to function.
- **Benchmark tools**: `wrk` (throughput), `hyperfine` (cold-start latency), `curl` (health checks).

## Build Outputs

| Path                            | Description                                               |
| ------------------------------- | --------------------------------------------------------- |
| `target/release/gateway_native` | Native gateway binary                                     |
| `target/release/gateway_host`   | WASM-host gateway binary                                  |
| `gateway_logic.wasm`            | WASM module (workspace root, produced by `build_wasm.sh`) |
