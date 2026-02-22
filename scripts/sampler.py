#!/usr/bin/env python3
"""
sampler.py — per-PID resource sampler for bench_throughput.sh

Usage:
    python3 scripts/sampler.py \
        --pid <liveness-pid> \
        --sample-pid <pid-to-measure>  \   # defaults to --pid
        --mode gateway|wasmedge         \
        --out <output.csv>              \
        --interval 0.2                      # seconds between samples

Output CSV columns: ts_ms, rss_kb, cpu_pct

CPU is measured as the fraction of one CPU used over the sample interval
(same definition as `top` / `htop`).  On Linux this is backed by
/proc/pid/stat tick deltas via psutil; on macOS it uses Mach task_info.

For mode=wasmedge the script aggregates all running `wasmedge` processes
(they are short-lived per-request subprocesses).
"""
import argparse
import signal
import sys
import time

try:
    import psutil
except ImportError:
    # Write header-only file and exit — caller treats missing samples as 0.
    import os, argparse as _ap
    p = _ap.ArgumentParser()
    p.add_argument("--out", default="/dev/null")
    args, _ = p.parse_known_args()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        f.write("ts_ms,rss_kb,cpu_pct\n")
    print("WARNING: psutil not installed — sampler wrote header-only file", file=sys.stderr)
    sys.exit(0)


def ts_ms() -> int:
    return int(time.time() * 1000)


def is_alive(pid: int) -> bool:
    try:
        return psutil.pid_exists(pid)
    except Exception:
        return False


def sample_gateway(proc: psutil.Process) -> tuple[int, float] | None:
    """Return (rss_kb, cpu_pct) or None if the process is gone."""
    try:
        mem = proc.memory_info()
        cpu = proc.cpu_percent()   # non-blocking after the first call primes the counter
        return mem.rss // 1024, cpu
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None


def sample_wasmedge() -> tuple[int, float]:
    """Aggregate RSS and CPU across all running wasmedge processes."""
    rss_kb = 0
    cpu_pct = 0.0
    for p in psutil.process_iter(["name", "cpu_percent", "memory_info"]):
        try:
            if p.info["name"] and p.info["name"].startswith("wasmedge"):
                rss_kb += (p.info["memory_info"].rss // 1024)
                cpu_pct += p.info["cpu_percent"] or 0.0
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return rss_kb, cpu_pct


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid",        type=int, required=True,
                        help="Liveness PID — sampler exits when this process dies.")
    parser.add_argument("--sample-pid", type=int, default=None,
                        help="PID to sample for RSS/CPU (defaults to --pid).")
    parser.add_argument("--mode",       choices=["gateway", "wasmedge"], default="gateway")
    parser.add_argument("--out",        required=True)
    parser.add_argument("--interval",   type=float, default=0.2)
    args = parser.parse_args()

    sample_pid = args.sample_pid if args.sample_pid is not None else args.pid

    # Ignore SIGTERM/SIGINT gracefully so the finally block always flushes.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT,  lambda *_: sys.exit(0))

    proc = None
    if args.mode == "gateway":
        try:
            proc = psutil.Process(sample_pid)
            # Prime the CPU counter — first cpu_percent() always returns 0.0
            proc.cpu_percent()
        except psutil.NoSuchProcess:
            pass

    with open(args.out, "w", buffering=1) as f:   # line-buffered
        f.write("ts_ms,rss_kb,cpu_pct\n")

        while is_alive(args.pid):
            time.sleep(args.interval)

            if args.mode == "wasmedge":
                rss_kb, cpu_pct = sample_wasmedge()
            else:
                if proc is None:
                    break
                result = sample_gateway(proc)
                if result is None:
                    break
                rss_kb, cpu_pct = result

            f.write(f"{ts_ms()},{rss_kb},{cpu_pct:.2f}\n")


if __name__ == "__main__":
    main()
