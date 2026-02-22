#!/usr/bin/env python3
"""
plot_results.py — Generate benchmark plots for wasm-vs-docker-gateway.

Usage:
    python3 scripts/plot_results.py [--out results/plots]
                                    [--throughput results/aggregated/throughput_analysis.csv]
                                    [--cold-start results/cold_start_YYYYMMDD_HHMMSS.csv]
                                    [--warm-latency results/warm_latency_YYYYMMDD_HHMMSS.csv]

Outputs (written to --out directory):
    throughput_{workload}.png      (4 plots: hello, compute, state, proxy)
    latency_{workload}.png         (4 plots)
    cpu_{workload}.png             (4 plots)
    memory_{workload}.png          (4 plots)
    cold_start.png
    warm_latency.png
"""

import argparse
import glob
import os
import sys

import matplotlib
matplotlib.use("Agg")  # headless — no display required
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import pandas as pd

# ── colour / style constants ─────────────────────────────────────────────────
VARIANT_STYLE = {
    "native_local":  {"color": "#2196F3", "marker": "o", "label": "native (local)"},
    "native_docker": {"color": "#4CAF50", "marker": "s", "label": "native (docker)"},
    "wasm_host_cli": {"color": "#FF9800", "marker": "^", "label": "wasm host (CLI)"},
}
WORKLOADS   = ["hello", "compute", "state", "proxy"]
FIGSIZE_LINE = (7, 4.5)
FIGSIZE_BAR  = (6, 4.5)
DPI          = 140


def latest_glob(pattern: str) -> str | None:
    """Return the lexicographically last file matching a glob, or None."""
    files = sorted(glob.glob(pattern))
    return files[-1] if files else None


def style(variant: str) -> dict:
    return VARIANT_STYLE.get(
        variant,
        {"color": "#9C27B0", "marker": "D", "label": variant},
    )


def save(fig: plt.Figure, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fig.savefig(path, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {path}")


# ─────────────────────────────────────────────────────────────────────────────
# Throughput data helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_throughput(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    # Average duplicate (variant, workload, conns) rows from repeated bench runs
    numeric = [c for c in df.columns if c not in ("run_ts", "variant", "workload", "conns")]
    df[numeric] = df[numeric].apply(pd.to_numeric, errors="coerce")
    df = (
        df.groupby(["variant", "workload", "conns"], as_index=False)[numeric]
        .mean(numeric_only=True)
    )
    df = df.sort_values(["variant", "workload", "conns"])
    return df


def line_plot(
    df: pd.DataFrame,
    workload: str,
    y_col: str,
    y_label: str,
    title: str,
    out_path: str,
    footnote: str = "",
) -> None:
    sub = df[df["workload"] == workload]
    variants = sorted(sub["variant"].unique(), key=lambda v: list(VARIANT_STYLE).index(v)
                      if v in VARIANT_STYLE else 99)

    fig, ax = plt.subplots(figsize=FIGSIZE_LINE)

    for v in variants:
        vdf = sub[sub["variant"] == v].sort_values("conns")
        s   = style(v)
        ax.plot(
            vdf["conns"], vdf[y_col],
            color=s["color"], marker=s["marker"],
            label=s["label"], linewidth=2, markersize=6,
        )
        # Annotate single-point lines so the value is still readable
        if len(vdf) == 1:
            ax.annotate(
                f"{vdf[y_col].iloc[0]:.1f}",
                xy=(vdf["conns"].iloc[0], vdf[y_col].iloc[0]),
                xytext=(6, 4), textcoords="offset points",
                fontsize=8, color=s["color"],
            )

    ax.set_xlabel("Concurrent connections")
    ax.set_ylabel(y_label)
    ax.set_title(title)
    ax.legend(fontsize=9)
    ax.grid(True, linestyle="--", alpha=0.4)
    if footnote:
        fig.text(0.5, -0.04, footnote, ha="center", fontsize=7, color="#888888",
                 style="italic", wrap=True)

    save(fig, out_path)


# ─────────────────────────────────────────────────────────────────────────────
# Plots 1–4: per-workload line plots
# ─────────────────────────────────────────────────────────────────────────────

def plot_throughput(df: pd.DataFrame, out_dir: str) -> None:
    print("\n[1] Throughput (RPS vs conns)")
    for wl in WORKLOADS:
        line_plot(
            df, wl,
            y_col="rps",
            y_label="Requests / sec",
            title=f"Throughput — {wl}",
            out_path=os.path.join(out_dir, f"throughput_{wl}.png"),
        )


def plot_latency(df: pd.DataFrame, out_dir: str) -> None:
    print("\n[2] Latency (mean ms vs conns)")
    for wl in WORKLOADS:
        line_plot(
            df, wl,
            y_col="latency_mean_ms",
            y_label="Mean latency (ms)",
            title=f"Latency — {wl}",
            out_path=os.path.join(out_dir, f"latency_{wl}.png"),
        )


def plot_cpu(df: pd.DataFrame, out_dir: str) -> None:
    y_col = "total_cpu_avg" if "total_cpu_avg" in df.columns else "gateway_cpu_avg"
    print(f"\n[3] CPU utilisation ({y_col} vs conns)")
    note = (
        "Point estimate from aggregated means. Interpret CPU together with RPS/latency; "
        "CPU alone is not a performance ranking."
    )
    for wl in WORKLOADS:
        line_plot(
            df, wl,
            y_col=y_col,
            y_label="Total CPU avg (%)",
            title=f"CPU utilisation — {wl}",
            out_path=os.path.join(out_dir, f"cpu_{wl}.png"),
            footnote=note,
        )


def plot_memory(df: pd.DataFrame, out_dir: str) -> None:
    y_col = "total_rss_avg_kb" if "total_rss_avg_kb" in df.columns else "gateway_rss_avg_kb"
    print(f"\n[4] Memory RSS ({y_col} vs conns)")
    note = "Point estimate from aggregated means; memory values are per-variant process totals."
    for wl in WORKLOADS:
        # Convert KB → MB for readability
        tmp = df.copy()
        tmp["rss_avg_mb"] = tmp[y_col] / 1024.0
        line_plot(
            tmp, wl,
            y_col="rss_avg_mb",
            y_label="Total RSS avg (MB)",
            title=f"Memory — {wl}",
            out_path=os.path.join(out_dir, f"memory_{wl}.png"),
            footnote=note,
        )


# ─────────────────────────────────────────────────────────────────────────────
# Plots 5–6: bar charts
# ─────────────────────────────────────────────────────────────────────────────

def bar_chart(
    means: dict[str, float],
    errors: dict[str, float],
    y_label: str,
    title: str,
    out_path: str,
    footnote: str = "",
) -> None:
    """Generic bar chart.  means/errors keyed by variant name."""
    variants = [v for v in VARIANT_STYLE if v in means]  # canonical order
    labels   = [style(v)["label"] for v in variants]
    values   = [means[v] for v in variants]
    errs     = [errors.get(v, 0) for v in variants]
    colors   = [style(v)["color"] for v in variants]

    fig, ax = plt.subplots(figsize=FIGSIZE_BAR)
    bars = ax.bar(labels, values, yerr=errs, color=colors, capsize=5,
                  alpha=0.85, edgecolor="white", linewidth=0.8)

    # Value labels on top of bars
    for bar, val, err in zip(bars, values, errs):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + err + max(values) * 0.01,
            f"{val:.1f}",
            ha="center", va="bottom", fontsize=9, fontweight="bold",
        )

    ax.set_ylabel(y_label)
    ax.set_title(title)
    ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    ax.set_ylim(bottom=0)
    if footnote:
        fig.text(0.5, -0.04, footnote, ha="center", fontsize=7,
                 color="#888888", style="italic")

    save(fig, out_path)


def plot_cold_start(path: str, out_dir: str) -> None:
    print("\n[5] Cold start")
    df = pd.read_csv(path)
    if "run_ms" not in df.columns:
        print(f"  SKIP: cold_start CSV missing 'run_ms' column. "
              f"Found: {list(df.columns)}. "
              f"File: {path}", file=sys.stderr)
        return
    if df.empty:
        print(f"  SKIP: cold_start CSV has no data rows ({path})", file=sys.stderr)
        return
    df["run_ms"] = pd.to_numeric(df["run_ms"], errors="coerce")

    means  = df.groupby("variant")["run_ms"].mean().to_dict()
    stdevs = df.groupby("variant")["run_ms"].std().to_dict()

    note = (
        "native_docker run 1 (Docker page-cache cold) is included; "
        "subsequent runs benefit from layer caching — see raw CSV for details."
    )
    bar_chart(
        means, stdevs,
        y_label="Startup latency (ms)",
        title="Cold start — time to first response",
        out_path=os.path.join(out_dir, "cold_start.png"),
        footnote=note,
    )


def plot_warm_latency(path: str, out_dir: str) -> None:
    print("\n[6] Warm latency")
    df = pd.read_csv(path)
    if "run_ms" not in df.columns:
        print(f"  SKIP: warm_latency CSV missing 'run_ms' column. "
              f"Found: {list(df.columns)}. "
              f"File: {path}", file=sys.stderr)
        return
    if df.empty:
        print(f"  SKIP: warm_latency CSV has no data rows ({path})", file=sys.stderr)
        return
    df["run_ms"] = pd.to_numeric(df["run_ms"], errors="coerce")

    means  = df.groupby("variant")["run_ms"].mean().to_dict()
    stdevs = df.groupby("variant")["run_ms"].std().to_dict()

    bar_chart(
        means, stdevs,
        y_label="Round-trip latency (ms)",
        title="Warm latency — curl round-trip (300 runs, warmup=20)",
        out_path=os.path.join(out_dir, "warm_latency.png"),
    )


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    # Always resolve root relative to this script file, not the cwd
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    results_dir = os.path.join(root, "results")

    parser = argparse.ArgumentParser(description="Plot benchmark results")
    parser.add_argument("--out", default=os.path.join(results_dir, "plots"),
                        help="Output directory for PNG files")
    parser.add_argument("--throughput",
                        default=None,
                        help="throughput_analysis.csv (or throughput.csv)")
    parser.add_argument("--cold-start",  dest="cold_start",  default=None)
    parser.add_argument("--warm-latency", dest="warm_latency", default=None)
    args = parser.parse_args()

    # Auto-discover files if not specified
    if args.throughput is None:
        analysis = os.path.join(results_dir, "aggregated", "throughput_analysis.csv")
        fallback = os.path.join(results_dir, "aggregated", "throughput.csv")
        args.throughput = analysis if os.path.exists(analysis) else fallback

    if args.cold_start is None:
        args.cold_start = latest_glob(os.path.join(results_dir, "cold_start_*.csv"))

    if args.warm_latency is None:
        args.warm_latency = latest_glob(os.path.join(results_dir, "warm_latency_*.csv"))

    # Report what we found
    print(f"throughput  : {args.throughput}")
    print(f"cold_start  : {args.cold_start}")
    print(f"warm_latency: {args.warm_latency}")
    print(f"output dir  : {args.out}")

    # ── Throughput / latency / CPU / memory plots ──────────────────────────
    if args.throughput and os.path.exists(args.throughput):
        df = load_throughput(args.throughput)
        plot_throughput(df, args.out)
        plot_latency(df, args.out)
        plot_cpu(df, args.out)
        plot_memory(df, args.out)
    else:
        print(f"WARN: throughput CSV not found: {args.throughput}", file=sys.stderr)

    # ── Cold start ─────────────────────────────────────────────────────────
    if args.cold_start and os.path.exists(args.cold_start):
        plot_cold_start(args.cold_start, args.out)
    else:
        print(f"WARN: cold_start CSV not found: {args.cold_start}", file=sys.stderr)

    # ── Warm latency ───────────────────────────────────────────────────────
    if args.warm_latency and os.path.exists(args.warm_latency):
        plot_warm_latency(args.warm_latency, args.out)
    else:
        print(f"WARN: warm_latency CSV not found: {args.warm_latency}", file=sys.stderr)

    n = len(os.listdir(args.out)) if os.path.isdir(args.out) else 0
    print(f"\nDone. {n} files in {args.out}/")


if __name__ == "__main__":
    main()
