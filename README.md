# WebAssembly vs Docker Gateway — Performance Benchmark Study

**Course:** RSX207 (CNAM) — Final report (2025–26)

**Authors / Supervisors:** N. Modina, S. Secci — Student: D. Khvedelidze

---

## Abstract

This repository contains a reproducible benchmark study comparing five HTTP
gateway deployment variants on a Linux KVM virtual machine. Evaluated
execution models:

- native Rust binary (host)
- same binary inside Docker
- gateway delegating request logic to a Wasm module via in-process Wasmtime
- gateway spawning `wasmtime run` CLI per request
- gateway spawning `wasmedge` CLI per request

Benchmarks measure cold-start latency, warm-request latency, sustained
throughput across concurrency levels, and resource consumption (RSS, CPU).
Workloads: `hello` (no-op), `compute` (SHA-256 chain), `state` (atomic
counter), and `proxy` (forwards to upstream). All gateway code is
single-threaded and blocking to isolate runtime overhead.

---

## Table of contents

- Motivation
- Goals & hypotheses
- Experimental design
- Implementation
- Results
- Discussion
- Limitations
- Future work
- Conclusion
- Appendix

---

## Motivation

Edge and serverless systems are sensitive to startup latency and per-instance
resource footprint. Containers introduce overheads (network namespaces,
overlay FS, cgroups), while WebAssembly promises low instantiation time and a
sandboxed runtime. This project compares native, containerised, and Wasm-based
HTTP gateway middleware under controlled conditions and provides a
reproducible benchmark pipeline and dataset.

## Goals and hypotheses

Goals

- Measure cold-start latency (exec → first HTTP 200) for five variants
- Measure warm-request latency (p50, p90, p99)
- Compare sustained throughput (RPS) across four workloads and seven
  concurrency levels
- Quantify resource consumption (RSS, CPU, CPU per 1k RPS)
- Provide an automated, reproducible benchmark pipeline with timestamped
  outputs and environment snapshots

Hypotheses

1. Native execution is the lowest-latency, highest-throughput baseline.
2. Docker cold-start will be noticeably slower than native.
3. Embedded Wasmtime should approach native warm-latency (no fork).
4. CLI-based Wasm variants (`wasmtime`, `wasmedge`) will hit throughput
   ceilings due to per-request process-spawn overhead.
5. For CPU-bound workloads the runtime invocation overhead will be
   negligible compared to computation cost.

## Experimental design

### Evaluated variants

- `native_local`: single Rust binary on the host (baseline)
- `native_docker`: same binary inside Docker
- `wasm_host_wasmtime_embedded`: Wasmtime embedded in-process (module
  compiled once; per-request `Store` + WASI context)
- `wasm_host_wasmtime`: spawn `wasmtime run` per request (stdin/stdout IPC)
- `wasm_host_cli`: spawn `wasmedge` CLI per request

Critical distinction: the two CLI-based Wasm variants spawn an OS process
per request; their throughput ceilings are governed by process-spawn costs,
not steady-state Wasm execution speed.

### Platform & environment

Representative testbed values (see `results/meta/env_snapshot_*.txt` for
full snapshot):

- Host OS: Linux (KVM VM), 4 cores
- RAM: 15 GiB total
- Rust: 1.93.1 (2026-02-11)
- Wasmtime v41 (embedded + CLI), WasmEdge CLI
- Tools: `wrk`, `hyperfine`, `curl`

All benchmarks target loopback `127.0.0.1`. Docker runs natively on Linux in
this testbed.

### Workloads

Four workloads exercise different cost profiles:

- `hello` — GET / — returns "hello" (or "wasm:hello" for Wasm variants).
- `compute` — GET /compute?iters=20000 — 20,000 SHA-256 iterations (CPU-bound)
- `state` — GET /state — atomic counter using `AtomicU64::fetch_add`
- `proxy` — GET /<any> — forwards to `http-echo` upstream on port 18080

In Wasm variants the response body is transformed (prepend `wasm:`) to isolate
invocation mechanism overhead from application cost. The Wasm module
(`gateway_wasm`) targets `wasm32-wasip1` and has no runtime dependencies.

### Benchmark methodology

- Cold start: `hyperfine --warmup 0 --runs 20` — spawn gateway, poll `/health`,
  fire one `curl`, then `kill -9`. Three repeats → N=60 samples.
- Warm latency: `hyperfine --warmup 20 --runs 300` — gateway started once;
  each iteration runs `curl -fsS http://127.0.0.1:18081/`. Note: `curl` adds
  ~8 ms startup overhead; compare relative differences.
- Throughput: `wrk` (4 threads) at connection levels [10,50,100,200,400,800,1200]
  for 30s runs. A Python `psutil` sampler records RSS and CPU every 200 ms.

Data pipeline: `scripts/bench_all.sh` orchestrates runs, writes raw files to
`results/`, computes summaries to `results/summary/`, aggregates to
`results/aggregated/throughput.csv`, and produces plots in `results/plots/`.

## Implementation

The workspace contains three crates:

- `gateway_native`: blocking, single-threaded TCP gateway implemented with
  `std::net::TcpStream`.
- `gateway_host`: gateway that delegates response-body transform to the Wasm
  module. Supports runtime modes via `WASM_RUNTIME`: `wasmedge`, `wasmtime`,
  `wasmtime_embedded`.
- `gateway_wasm`: minimal WASI module reading stdin and writing stdout with a
  simple prepend transform.

No async runtimes are used; all I/O is blocking with explicit timeouts.

### Embedded Wasmtime caching

The `wasmtime_embedded` mode compiles the Wasm module once and caches the
`Engine` + `Module` pair. Each request creates a fresh `Store` and WASI
context, instantiates the module, calls `_start`, and reads the output pipe.
This amortises compilation while keeping per-request isolation.

### Scripts

- `scripts/bench_cold_start.sh` — cold-start benchmark
- `scripts/bench_warm_latency.sh` — warm latency
- `scripts/bench_throughput.sh` — throughput + resource sampling
- `scripts/bench_all.sh` — orchestrator for all benchmarks
- `scripts/run_native_local.sh`, `scripts/run_docker.sh`,
  `scripts/run_wasm_host_local.sh` — per-variant launchers

Development notes and challenges are captured in the original LaTeX report.

## Results (summary)

Key findings (full CSVs and plots in `results/`):

- Cold start: non-Docker variants start under ~260 ms (p99). Native p50 ~176 ms;
  embedded Wasmtime cold-start includes compilation (~232 ms p50). Docker is
  much slower (p50 ~3143 ms) due to image and namespace init.
- Warm latency (hello): native, Docker, and embedded Wasm cluster closely
  (p50 ≈ 8.8–9.4 ms); CLI Wasm adds ~12–18 ms due to process creation.
- Throughput (hello): native peaks at ~22,745 RPS (100 connections); Docker
  stabilises ~9k RPS; embedded Wasm ~3.6k RPS; CLI variants ≈100 RPS or less
  (process-spawn limited).
- Throughput (compute): CPU-bound workload (~20k SHA-256 iterations) levels
  native, Docker, and embedded Wasm at ≈130 RPS — computation dominates.
- Resource footprint: embedded Wasm uses more memory (~19 MB) vs native (~0.8 MB).

For complete tables and plots, see the files in `results/summary/` and
`results/plots/`.

## Discussion

- Cold-start: Wasm variants outperform Docker for cold-start latency on this
  testbed by an order of magnitude.
- Warm latency: embedded Wasmtime (in-process) is near-native in steady state.
- Throughput: for trivial handlers native outperforms embedded Wasm by several
  times; for CPU-bound workloads the gap closes as computation dominates.
- Trade-offs: embedded Wasm provides per-request sandboxing at memory and
  CPU cost; CLI-based Wasm measures process-spawn overhead (worst-case).

## Limitations

- Loopback-only benchmarks; results may differ over networked hosts.
- Load generator (`wrk`) runs on same machine as the gateway; at high
  concurrency scheduling interference may occur.
- KVM virtualisation may introduce variance vs bare metal.
- Single-threaded gateway design limits scalability (deliberate for fairness).
- `curl` adds ~8 ms to warm-latency measurements.
- 200 ms resource sampling misses short-lived CLI child processes.

## Future work

- Run on bare-metal hardware.
- Replace `curl`-based warm-latency with a persistent-connection client.
- Add a multi-threaded gateway variant.
- Benchmark a non-trivial Wasm plugin (e.g., JSON transform).
- Compare Wasmtime AOT vs JIT-on-first-use.
- Add Firecracker/gVisor baselines.

## Conclusion

The benchmark suite provides a reproducible comparison of native, Docker, and
Wasm gateway variants. Main takeaways (scoped to this testbed):

1. Cold start: Wasm variants add ~14–56 ms over native; Docker is much slower.
2. Warm latency: Docker and embedded Wasm are within ~1 ms of native (p50).
3. Throughput (hello): native >> embedded Wasm >> CLI Wasm.
4. Throughput (CPU-bound): runtimes converge when computation dominates.
5. Resources: embedded Wasm uses more memory and CPU per unit of trivial
   throughput.

No universal claim that "Wasm is faster than Docker" is supported; results
depend on workload and platform.

## How to run (quick)

Build all native binaries:

```bash
cargo build --release
```

Build WASM module (required before wasm_host variant):

```bash
./scripts/build_wasm.sh
```

Start upstream (requires Docker):

```bash
docker compose up -d upstream
```

Run native gateway locally (loads `configs/bench.env`):

```bash
./scripts/run_native_local.sh
```

Run WASM-host gateway locally:

```bash
./scripts/run_wasm_host_local.sh
```

Run full benchmark suite (requires `wrk`, `hyperfine`, `curl`):

```bash
./scripts/bench_all.sh
```

Benchmark outputs and aggregates land under `results/`.

## References

- Wasmtime: https://github.com/bytecodealliance/wasmtime
- WasmEdge: https://github.com/WasmEdge/WasmEdge
- Docker: https://www.docker.com
- wrk: https://github.com/wg/wrk
- hyperfine: https://github.com/sharkdp/hyperfine

## Appendix

Additional tables and plots are available in `results/plots/` and
`results/summary/`.

---
