#!/usr/bin/env python3
# How to run:
#   python3 scripts/analyze_results.py
#   python3 scripts/analyze_results.py --results-dir results
#   python3 scripts/analyze_results.py --throughput results/aggregated/throughput.csv \
#       --throughput-analysis results/aggregated/throughput_analysis.csv \
#       --cold-start results/aggregated/cold_start.csv \
#       --warm-latency results/aggregated/warm_latency.csv
#
# Outputs:
#   - Summary CSVs: results/summary/*.csv
#   - Plot PNGs:    results/plots/*.png

from __future__ import annotations

import argparse
import glob
import os
from typing import Iterable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


VARIANT_STYLE = {
    "native_local": {"color": "#1f77b4", "marker": "o", "label": "native_local"},
    "native_docker": {"color": "#2ca02c", "marker": "s", "label": "native_docker"},
    "wasm_host_cli": {"color": "#ff7f0e", "marker": "^", "label": "wasm_host_cli"},
    "wasm_host_wasmtime": {"color": "#d62728", "marker": "D", "label": "wasm_host_wasmtime"},
}


def log(msg: str) -> None:
    print(msg)


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def read_csv_if_exists(path: str | None, label: str) -> pd.DataFrame | None:
    if not path:
        log(f"[skip] {label}: no path provided")
        return None
    if not os.path.exists(path):
        log(f"[skip] {label}: missing file {path}")
        return None
    df = pd.read_csv(path)
    log(f"[load] {label}: {path} ({len(df)} rows)")
    return df


def read_csvs_if_exist(paths: list[str], label: str) -> pd.DataFrame | None:
    existing = [p for p in paths if os.path.exists(p)]
    if not existing:
        log(f"[skip] {label}: no files found")
        return None
    frames: list[pd.DataFrame] = []
    for path in existing:
        df = pd.read_csv(path)
        frames.append(df)
        log(f"[load] {label}: {path} ({len(df)} rows)")
    return pd.concat(frames, ignore_index=True) if frames else None


def coerce_numeric(df: pd.DataFrame, cols: Iterable[str]) -> None:
    for col in cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")


def variant_sort_key(variant: str) -> tuple[int, str]:
    known_order = list(VARIANT_STYLE.keys())
    if variant in known_order:
        return (known_order.index(variant), variant)
    return (999, variant)


def style_for_variant(variant: str) -> dict[str, str]:
    return VARIANT_STYLE.get(
        variant,
        {"color": "#7f7f7f", "marker": "o", "label": variant},
    )


def normalize_throughput_frame(df: pd.DataFrame, source_name: str) -> pd.DataFrame:
    out = df.copy()
    out.columns = [c.strip() for c in out.columns]
    out = out.replace(["NA", "N/A", "na", "n/a", ""], pd.NA)

    for required in ("variant", "workload"):
        if required not in out.columns:
            out[required] = "unknown"

    if "rps" not in out.columns and "requests_per_sec" in out.columns:
        out["rps"] = out["requests_per_sec"]
    if "latency_mean_ms" not in out.columns and "latency_ms" in out.columns:
        out["latency_mean_ms"] = out["latency_ms"]

    numeric_candidates = [
        "conns",
        "threads",
        "duration_s",
        "rps",
        "latency_mean_ms",
        "gateway_rss_avg_kb",
        "gateway_cpu_avg",
        "wasmedge_rss_avg_kb",
        "wasmedge_cpu_avg",
        "total_rss_avg_kb",
        "total_cpu_avg",
        "rss_avg_kb",
        "cpu_avg",
    ]
    coerce_numeric(out, numeric_candidates)

    if "total_rss_avg_kb" in out.columns:
        out["rss_avg_kb"] = out["total_rss_avg_kb"]
    elif "rss_avg_kb" in out.columns:
        pass
    elif "gateway_rss_avg_kb" in out.columns and "wasmedge_rss_avg_kb" in out.columns:
        out["rss_avg_kb"] = out["gateway_rss_avg_kb"].fillna(0) + out["wasmedge_rss_avg_kb"].fillna(0)
    elif "gateway_rss_avg_kb" in out.columns:
        out["rss_avg_kb"] = out["gateway_rss_avg_kb"]
    else:
        out["rss_avg_kb"] = pd.NA

    if "total_cpu_avg" in out.columns:
        out["cpu_avg"] = out["total_cpu_avg"]
    elif "cpu_avg" in out.columns:
        pass
    elif "gateway_cpu_avg" in out.columns and "wasmedge_cpu_avg" in out.columns:
        out["cpu_avg"] = out["gateway_cpu_avg"].fillna(0) + out["wasmedge_cpu_avg"].fillna(0)
    elif "gateway_cpu_avg" in out.columns:
        out["cpu_avg"] = out["gateway_cpu_avg"]
    else:
        out["cpu_avg"] = pd.NA

    out["_source"] = source_name
    out["_priority"] = 2 if source_name == "throughput_analysis" else 1
    return out


def load_throughput(
    throughput_path: str | None,
    throughput_analysis_path: str | None,
) -> pd.DataFrame | None:
    frames: list[pd.DataFrame] = []

    throughput_df = read_csv_if_exists(throughput_path, "throughput")
    if throughput_df is not None and not throughput_df.empty:
        frames.append(normalize_throughput_frame(throughput_df, "throughput"))

    throughput_analysis_df = read_csv_if_exists(throughput_analysis_path, "throughput_analysis")
    if throughput_analysis_df is not None and not throughput_analysis_df.empty:
        frames.append(normalize_throughput_frame(throughput_analysis_df, "throughput_analysis"))

    if not frames:
        return None

    all_rows = pd.concat(frames, ignore_index=True)
    dedup_cols = [
        col
        for col in ("run_ts", "variant", "workload", "conns", "threads", "duration_s")
        if col in all_rows.columns
    ]

    all_rows = all_rows.sort_values(["_priority"], ascending=False)
    if dedup_cols:
        all_rows = all_rows.drop_duplicates(subset=dedup_cols, keep="first")

    needed = ["variant", "workload", "conns", "rps", "latency_mean_ms", "rss_avg_kb", "cpu_avg"]
    for col in needed:
        if col not in all_rows.columns:
            all_rows[col] = pd.NA

    coerce_numeric(all_rows, ["conns", "threads", "duration_s", "rps", "latency_mean_ms", "rss_avg_kb", "cpu_avg"])
    return all_rows


def summarize_throughput(df: pd.DataFrame) -> pd.DataFrame:
    group_cols = ["variant", "workload", "conns"]
    for optional in ("threads", "duration_s"):
        if optional in df.columns:
            group_cols.append(optional)

    summary = (
        df.groupby(group_cols, dropna=False)
        .agg(
            sample_count=("variant", "size"),
            mean_rps=("rps", "mean"),
            mean_latency_ms=("latency_mean_ms", "mean"),
            mean_rss_kb=("rss_avg_kb", "mean"),
            mean_cpu=("cpu_avg", "mean"),
        )
        .reset_index()
    )
    summary["cpu_per_1k_rps"] = pd.NA
    mask = summary["mean_rps"] > 0
    summary.loc[mask, "cpu_per_1k_rps"] = summary.loc[mask, "mean_cpu"] / (summary.loc[mask, "mean_rps"] / 1000.0)
    summary["cpu_per_1k_rps"] = pd.to_numeric(summary["cpu_per_1k_rps"], errors="coerce")

    summary = summary.sort_values(
        by=["workload", "variant", "conns"] + [c for c in ("threads", "duration_s") if c in summary.columns]
    )
    return summary


def collapse_for_line_plots(summary: pd.DataFrame) -> pd.DataFrame:
    return (
        summary.groupby(["variant", "workload", "conns"], dropna=False)
        .agg(
            mean_rps=("mean_rps", "mean"),
            mean_latency_ms=("mean_latency_ms", "mean"),
            mean_rss_kb=("mean_rss_kb", "mean"),
            mean_cpu=("mean_cpu", "mean"),
            cpu_per_1k_rps=("cpu_per_1k_rps", "mean"),
            sample_count=("sample_count", "sum"),
        )
        .reset_index()
        .sort_values(["workload", "variant", "conns"])
    )


def save_line_plot(
    df: pd.DataFrame,
    workload: str,
    y_col: str,
    y_label: str,
    title: str,
    out_path: str,
) -> None:
    sub = df[df["workload"] == workload].copy()
    if sub.empty or y_col not in sub.columns:
        return

    fig, ax = plt.subplots(figsize=(8, 4.8))
    variants = sorted(sub["variant"].dropna().unique(), key=variant_sort_key)

    for variant in variants:
        vdf = sub[sub["variant"] == variant].sort_values("conns")
        s = style_for_variant(variant)
        ax.plot(
            vdf["conns"],
            vdf[y_col],
            label=s["label"],
            color=s["color"],
            marker=s["marker"],
            linewidth=2,
        )

    ax.set_title(title)
    ax.set_xlabel("Concurrent connections")
    ax.set_ylabel(y_label)
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.legend(fontsize=9)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    log(f"[write] plot: {out_path}")


def percentile_summary(df: pd.DataFrame, group_cols: list[str], value_col: str) -> pd.DataFrame:
    grouped = df.groupby(group_cols, dropna=False)[value_col]
    q = grouped.quantile([0.50, 0.90, 0.99]).unstack(level=-1).reset_index()
    rename_map = {0.50: "p50_ms", 0.90: "p90_ms", 0.99: "p99_ms"}
    q = q.rename(columns=rename_map)
    counts = grouped.size().reset_index(name="sample_count")
    out = q.merge(counts, on=group_cols, how="left")
    return out


def detect_ms_column(df: pd.DataFrame) -> str | None:
    candidates = [
        "run_ms",
        "startup_ms",
        "latency_ms",
        "duration_ms",
        "time_ms",
    ]
    for col in candidates:
        if col in df.columns:
            return col
    return None


def plot_cold_start(summary: pd.DataFrame, out_path: str) -> None:
    if summary.empty:
        return
    summary = summary.sort_values("variant", key=lambda s: s.map(lambda v: variant_sort_key(v)))
    x = list(range(len(summary)))
    width = 0.38

    fig, ax = plt.subplots(figsize=(max(6, len(summary) * 1.2), 4.8))
    p50 = summary["p50_ms"].fillna(0)
    p90 = summary["p90_ms"].fillna(0)
    variants = summary["variant"].tolist()
    colors = [style_for_variant(v)["color"] for v in variants]

    ax.bar([i - width / 2 for i in x], p50, width=width, label="p50 (median)", color=colors, alpha=0.85)
    ax.bar([i + width / 2 for i in x], p90, width=width, label="p90", color=colors, alpha=0.45)
    ax.set_xticks(x)
    ax.set_xticklabels(variants, rotation=20, ha="right")
    ax.set_ylabel("Startup time (ms)")
    ax.set_title("Cold Start Latency by Variant")
    ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    log(f"[write] plot: {out_path}")


def plot_warm_latency(summary: pd.DataFrame, out_path: str) -> None:
    if summary.empty:
        return

    summary["__variant_order"] = summary["variant"].map(lambda v: variant_sort_key(v)[0] if isinstance(v, str) else 999)
    summary = summary.sort_values(["__variant_order", "variant", "workload"]).drop(columns=["__variant_order"])
    labels = [f"{row.variant}\n{row.workload}" for row in summary.itertuples()]
    x = list(range(len(summary)))
    width = 0.38

    fig, ax = plt.subplots(figsize=(max(8, len(summary) * 0.9), 5.2))
    p50 = summary["p50_ms"].fillna(0)
    p90 = summary["p90_ms"].fillna(0)

    ax.bar([i - width / 2 for i in x], p50, width=width, label="p50 (median)", color="#1f77b4", alpha=0.85)
    ax.bar([i + width / 2 for i in x], p90, width=width, label="p90", color="#ff7f0e", alpha=0.85)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=30, ha="right")
    ax.set_ylabel("Warm latency (ms)")
    ax.set_title("Warm Latency by Variant / Workload")
    ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    log(f"[write] plot: {out_path}")


def main() -> None:
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    default_results_dir = os.path.join(root, "results")

    parser = argparse.ArgumentParser(description="Analyze benchmark CSV outputs and generate summary tables/plots.")
    parser.add_argument("--results-dir", default=default_results_dir, help="Root results directory (default: results)")
    parser.add_argument("--throughput", default=None, help="Path to throughput.csv")
    parser.add_argument("--throughput-analysis", dest="throughput_analysis", default=None, help="Path to throughput_analysis.csv")
    parser.add_argument("--cold-start", dest="cold_start", default=None, help="Path to cold_start CSV")
    parser.add_argument("--warm-latency", dest="warm_latency", default=None, help="Path to warm_latency CSV")
    parser.add_argument("--summary-dir", default=None, help="Where to write summary CSV files")
    parser.add_argument("--plots-dir", default=None, help="Where to write plot PNG files")
    args = parser.parse_args()

    results_dir = os.path.realpath(args.results_dir)
    summary_dir = os.path.realpath(args.summary_dir) if args.summary_dir else os.path.join(results_dir, "summary")
    plots_dir = os.path.realpath(args.plots_dir) if args.plots_dir else os.path.join(results_dir, "plots")
    ensure_dir(summary_dir)
    ensure_dir(plots_dir)

    throughput_path = args.throughput or os.path.join(results_dir, "aggregated", "throughput.csv")
    throughput_analysis_path = args.throughput_analysis or os.path.join(results_dir, "aggregated", "throughput_analysis.csv")
    cold_start_path = args.cold_start
    cold_start_paths: list[str] = []
    if cold_start_path is None:
        agg_cold = os.path.join(results_dir, "aggregated", "cold_start.csv")
        if os.path.exists(agg_cold):
            cold_start_paths = [agg_cold]
        else:
            cold_start_paths = sorted(glob.glob(os.path.join(results_dir, "cold_start_*.csv")))
    else:
        cold_start_paths = [cold_start_path]

    warm_latency_path = args.warm_latency
    warm_latency_paths: list[str] = []
    if warm_latency_path is None:
        agg_warm = os.path.join(results_dir, "aggregated", "warm_latency.csv")
        if os.path.exists(agg_warm):
            warm_latency_paths = [agg_warm]
        else:
            warm_latency_paths = sorted(glob.glob(os.path.join(results_dir, "warm_latency_*.csv")))
    else:
        warm_latency_paths = [warm_latency_path]

    log("== Inputs ==")
    log(f"throughput           : {throughput_path}")
    log(f"throughput_analysis  : {throughput_analysis_path}")
    log(f"cold_start           : {cold_start_paths if cold_start_paths else None}")
    log(f"warm_latency         : {warm_latency_paths if warm_latency_paths else None}")
    log(f"summary_dir          : {summary_dir}")
    log(f"plots_dir            : {plots_dir}")

    throughput_raw = load_throughput(throughput_path, throughput_analysis_path)
    if throughput_raw is None or throughput_raw.empty:
        log("[skip] throughput summaries/plots: no data")
    else:
        throughput_summary = summarize_throughput(throughput_raw)
        throughput_summary_path = os.path.join(summary_dir, "throughput_summary.csv")
        throughput_summary.to_csv(throughput_summary_path, index=False)
        log(f"[write] summary: {throughput_summary_path}")

        throughput_plot_data = collapse_for_line_plots(throughput_summary)
        workloads = sorted(throughput_plot_data["workload"].dropna().unique())
        for workload in workloads:
            save_line_plot(
                throughput_plot_data,
                workload=workload,
                y_col="mean_rps",
                y_label="RPS",
                title=f"Throughput (RPS vs Conns) - {workload}",
                out_path=os.path.join(plots_dir, f"throughput_{workload}.png"),
            )
            save_line_plot(
                throughput_plot_data,
                workload=workload,
                y_col="mean_latency_ms",
                y_label="Mean latency (ms)",
                title=f"Latency (Mean ms vs Conns) - {workload}",
                out_path=os.path.join(plots_dir, f"latency_{workload}.png"),
            )
            save_line_plot(
                throughput_plot_data,
                workload=workload,
                y_col="mean_rss_kb",
                y_label="RSS avg (KB)",
                title=f"RSS (avg KB vs Conns) - {workload}",
                out_path=os.path.join(plots_dir, f"rss_{workload}.png"),
            )
            save_line_plot(
                throughput_plot_data,
                workload=workload,
                y_col="cpu_per_1k_rps",
                y_label="CPU per 1k RPS",
                title=f"Efficiency (CPU per 1k RPS vs Conns) - {workload}",
                out_path=os.path.join(plots_dir, f"efficiency_{workload}.png"),
            )

    cold_df = read_csvs_if_exist(cold_start_paths, "cold_start")
    if cold_df is None or cold_df.empty:
        log("[skip] cold start summaries/plots: no data")
    else:
        ms_col = detect_ms_column(cold_df)
        if ms_col is None:
            log(f"[skip] cold start: no ms column found in {list(cold_df.columns)}")
        else:
            cold_df = cold_df.replace(["NA", "N/A", "na", "n/a", ""], pd.NA)
            if "variant" not in cold_df.columns:
                cold_df["variant"] = "unknown"
            cold_df[ms_col] = pd.to_numeric(cold_df[ms_col], errors="coerce")
            cold_df = cold_df.dropna(subset=[ms_col])
            cold_summary = percentile_summary(cold_df, ["variant"], ms_col)
            cold_summary_path = os.path.join(summary_dir, "cold_start_percentiles.csv")
            cold_summary.to_csv(cold_summary_path, index=False)
            log(f"[write] summary: {cold_summary_path}")
            plot_cold_start(cold_summary, os.path.join(plots_dir, "cold_start_median_p90.png"))

    warm_df = read_csvs_if_exist(warm_latency_paths, "warm_latency")
    if warm_df is None or warm_df.empty:
        log("[skip] warm latency summaries/plots: no data")
    else:
        ms_col = detect_ms_column(warm_df)
        if ms_col is None:
            log(f"[skip] warm latency: no ms column found in {list(warm_df.columns)}")
        else:
            warm_df = warm_df.replace(["NA", "N/A", "na", "n/a", ""], pd.NA)
            if "variant" not in warm_df.columns:
                warm_df["variant"] = "unknown"
            if "workload" not in warm_df.columns:
                warm_df["workload"] = "default"
            warm_df[ms_col] = pd.to_numeric(warm_df[ms_col], errors="coerce")
            warm_df = warm_df.dropna(subset=[ms_col])
            warm_summary = percentile_summary(warm_df, ["variant", "workload"], ms_col)
            warm_summary_path = os.path.join(summary_dir, "warm_latency_percentiles.csv")
            warm_summary.to_csv(warm_summary_path, index=False)
            log(f"[write] summary: {warm_summary_path}")
            plot_warm_latency(warm_summary, os.path.join(plots_dir, "warm_latency_median_p90.png"))

    log("Done.")


if __name__ == "__main__":
    main()
