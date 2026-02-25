\documentclass[a4paper,12pt]{article}

\usepackage[english]{babel}
\usepackage{fancyhdr}
\usepackage[utf8]{inputenc}
\usepackage{epsfig}
\usepackage{calc}
\usepackage{url}
\IfFileExists{boxedminipage.sty}{%
  \usepackage{boxedminipage}%
}{%
  \newenvironment{boxedminipage}[1]{%
    \begin{center}%
    \fbox\bgroup%
    \begin{minipage}{##1}%
  }{%
    \end{minipage}%
    \egroup%
    \end{center}%
  }%
}
\usepackage{graphicx}
\usepackage{booktabs}
\usepackage{hyperref}
\usepackage{mathptmx}
\usepackage{siunitx}
\usepackage[table]{xcolor}
\IfFileExists{placeins.sty}{\usepackage{placeins}}{\newcommand{\FloatBarrier}{\clearpage}}
\usepackage{needspace}
\usepackage{caption}

\graphicspath{{figures/}}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Definitions to customize

\def\nomEncad{N.~Modina, S.~Secci}
\def\nomEtudA{D.~Khvedelidze}
\def\nomEtudB{}
\def\nomEtudC{}
\def\nomEtudD{}

\def\refProjet{9}
\def\titreProjetCourt{WASM Bench}
\def\titreProjetLong{WebAssembly vs Docker Gateway\\Performance Benchmark Study}

\def\typeDoc{Final report}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Definitions not to modify

\setlength{\voffset}{-1in}
\setlength{\topmargin}{15mm}
\setlength{\headheight}{20mm}
\setlength{\headsep}{10mm}
\setlength{\textheight}{220mm}
\setlength{\footskip}{12mm}

\setlength{\hoffset}{-1in}
\setlength{\oddsidemargin}{25mm}
\setlength{\evensidemargin}{25mm}
\setlength{\marginparwidth}{0mm}
\setlength{\marginparsep}{0mm}
\setlength{\textwidth}{160mm}

\def\annee{2025-26}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Document begins

\begin{document}

\selectlanguage{english}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Headers and footers
\pagestyle{fancyplain}
\lhead[\fancyplain{}{\texttt{National Conservatory of Arts and Crafts (CNAM)}\\
          Course \textbf{RSX207} Feb. \annee \\ \nomEncad}]
      {\fancyplain{}{\textsc{National Conservatory of Arts and Crafts (CNAM)}\\
          Course \textbf{RSX207} Feb. \annee \\ \nomEncad}}
\chead[\fancyplain{}{\textbf{Project \refProjet\\\titreProjetCourt}}]
      {\fancyplain{}{\textbf{Project \refProjet\\\titreProjetCourt}}}
\rhead[\fancyplain{}{\nomEtudA\\\nomEtudB\\\nomEtudC\\\nomEtudD}]
      {\fancyplain{}{\nomEtudA\\\nomEtudB\\\nomEtudC\\\nomEtudD}}
\lfoot[\fancyplain{}{%
  \IfFileExists{logo-cnam.png}{\includegraphics[width=3cm]{logo-cnam.png}}{\textbf{CNAM}}}]
      {\fancyplain{}{%
  \IfFileExists{logo-cnam.png}{\includegraphics[width=3cm]{logo-cnam.png}}{\textbf{CNAM}}}}
\cfoot[\fancyplain{}{\textbf{\thepage/\pageref{fin}}}]
      {\fancyplain{}{\textbf{\thepage/\pageref{fin}}}}
\rfoot[\fancyplain{}{\typeDoc}]
      {\fancyplain{}{\typeDoc}}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

~

\begin{center}
  \begin{boxedminipage}{12cm}
    \begin{center}
      ~\\\LARGE\textbf{\titreProjetLong}\\
      ~\\\large Supervisors: \textbf{\nomEncad}\\
      ~\\\large Student: \textbf{\nomEtudA}\\
      ~
    \end{center}
  \end{boxedminipage}
\end{center}

~

\setcounter{tocdepth}{2}
\tableofcontents

\newpage

%% ================================================================
\begin{abstract}
This report presents a reproducible benchmark study comparing the performance
overhead of five HTTP gateway deployment variants on a Linux KVM virtual
machine. The evaluated execution models are: (1)~a native Rust binary executed
directly on the host, (2)~the same binary inside a Docker container,
(3)~a gateway that delegates per-request logic to a WebAssembly module via an
embedded Wasmtime runtime (in-process), (4)~a gateway that spawns a
\texttt{wasmtime run} CLI subprocess per request, and (5)~a gateway that spawns
a \texttt{wasmedge} CLI subprocess per request. The benchmarks measure
cold-start latency, warm-request latency, sustained throughput under varying
concurrency, and resource consumption (RSS, CPU). Four workloads are tested:
a no-op ``hello'' endpoint, a CPU-bound SHA-256 chain, an atomic-counter
stateful endpoint, and a reverse-proxy forwarding to an upstream service.
All gateway code is single-threaded and blocking to isolate runtime overhead
from concurrency-framework effects. All results and conclusions are scoped to
this specific testbed and should not be generalised without further validation
on other platforms and workloads.
\end{abstract}

%% ================================================================
\section{Motivation}
\label{sec:motivation}

Edge and serverless systems are sensitive to startup latency and per-instance
resource footprint. Traditional Linux containers provide mature isolation and
packaging but introduce overhead from network namespaces, overlay filesystems,
and (on non-Linux hosts) a virtualisation layer. WebAssembly (Wasm) modules
offer an alternative execution model that promises sub-millisecond
instantiation and smaller memory use through a sandboxed, capability-based
runtime.

This project evaluates those claims empirically by constructing a testbed that
compares native, containerised, and Wasm-based HTTP gateway middleware under
controlled conditions. The contribution is a reproducible pipeline and a
dataset from which mechanistic explanations of observed overhead can be drawn.

%% ================================================================
\section{Goals and Hypotheses}
\label{sec:goals}

\subsection{Goals}
\begin{itemize}
  \item Measure cold-start latency (process launch to first HTTP~200) for five
        deployment variants.
  \item Measure warm-request latency at the p50, p90, and p99 percentiles.
  \item Compare sustained throughput (requests/second) across four workloads at
        seven concurrency levels.
  \item Quantify resource consumption (RSS, CPU, CPU per 1\,000~RPS) per
        variant.
  \item Produce a fully automated, reproducible benchmark pipeline with
        timestamped outputs and machine-environment snapshots.
\end{itemize}

\subsection{Hypotheses}
\begin{enumerate}
  \item Native execution should exhibit the lowest cold-start and highest
        throughput because it incurs no runtime indirection.
  \item Docker cold start should be substantially slower than native due to
        container-image initialisation and network-namespace setup.
  \item The embedded Wasmtime variant should approach native warm-latency
        because it avoids subprocess creation.
  \item CLI-based Wasm variants (wasmtime, wasmedge) should exhibit
        throughput ceilings proportional to their per-request process-spawn cost.
  \item For CPU-bound workloads, the invocation overhead of all variants
        should become negligible relative to the SHA-256 computation cost.
\end{enumerate}

%% ================================================================
\section{Experimental Design}
\label{sec:design}

\subsection{Evaluated Variants}
\label{sec:variants}

Five deployment variants are evaluated. Table~\ref{tab:variants} describes
the execution model and what each variant primarily measures.

\begin{table}[ht]
\centering
\small
\begin{tabular}{p{3.8cm}p{5.2cm}p{5.5cm}}
\toprule
\textbf{Variant} & \textbf{Execution model} & \textbf{What it measures} \\
\midrule
\texttt{native\_local}
  & Single Rust binary, direct process execution on the host.
  & Zero-overhead baseline. \\[4pt]
\texttt{native\_docker}
  & Same binary inside a Docker container (Linux, no Desktop VM).
  & Container isolation overhead: network namespace, overlay~FS,
    cgroup scheduling. \\[4pt]
\texttt{wasm\_host\_\allowbreak wasmtime\_\allowbreak embedded}
  & Gateway links the Wasmtime crate (v41) in-process. The Wasm
    module is compiled once; each request instantiates a new
    \texttt{Store}~+ WASI context.
  & In-process Wasm instantiation overhead per request. \\[4pt]
\texttt{wasm\_host\_\allowbreak wasmtime}
  & Gateway spawns \texttt{wasmtime run} as a child process per
    request, piping request/response via stdin/stdout.
  & Process-spawn + runtime-initialisation overhead (not intrinsic
    Wasm execution performance). \\[4pt]
\texttt{wasm\_host\_cli}
  & Same subprocess model, but using the \texttt{wasmedge} CLI.
  & Process-spawn + WasmEdge runtime-initialisation overhead. \\
\bottomrule
\end{tabular}
\caption{Evaluated deployment variants and what each primarily measures.}
\label{tab:variants}
\end{table}

\paragraph{Critical distinction.}
The two CLI-based Wasm variants fork a new operating-system process for every
HTTP request. Their throughput ceiling is therefore determined by process-spawn
overhead, not by the steady-state execution speed of WebAssembly. These
variants represent a worst-case isolation model and should not be conflated
with in-process Wasm execution.

\subsection{Platform and Environment}

\begin{table}[ht]
\centering
\begin{tabular}{ll}
\toprule
\textbf{Parameter} & \textbf{Value} \\
\midrule
Host OS & Linux 5.4.0-1032-kvm (Ubuntu, x86\_64) \\
CPU & 4 cores (KVM virtual machine) \\
RAM & \SI{15}{\gibi\byte} total, $\approx$\SI{13}{\gibi\byte} available \\
Rust & 1.93.1 (2026-02-11) \\
Wasmtime & v41 (embedded crate) + CLI \\
WasmEdge & latest CLI \\
Docker & Linux native (no Desktop VM) \\
\texttt{wrk} & 4.2.0 \\
\texttt{hyperfine} & 1.20.0 \\
\bottomrule
\end{tabular}
\caption{Testbed environment.
  Source: \texttt{results/meta/env\_snapshot\_20260222\_195454.txt}.}
\label{tab:env}
\end{table}

All benchmarks run on loopback (\texttt{127.0.0.1}). The Docker daemon runs
natively on Linux; there is no Docker Desktop virtualisation layer, unlike the
mid-term setup on macOS.

\subsection{Workloads}
\label{sec:workloads}

Four workloads exercise different cost profiles:

\begin{table}[ht]
\centering
\small
\begin{tabular}{llp{8cm}}
\toprule
\textbf{Workload} & \textbf{Endpoint} & \textbf{Description} \\
\midrule
hello   & \texttt{GET /}              & Returns \texttt{"hello"} (or \texttt{"wasm:hello"} for Wasm variants). No-op baseline. \\
compute & \texttt{GET /compute?iters=20000} & Chains 20\,000 SHA-256 iterations. CPU-bound. \\
state   & \texttt{GET /state}         & Atomic counter (\texttt{AtomicU64::fetch\_add}). Stateful request handling. \\
proxy   & \texttt{GET /<any>}         & Forwards to \texttt{http-echo} upstream on port 18080. Network-I/O-bound. \\
\bottomrule
\end{tabular}
\caption{Benchmark workloads.}
\label{tab:workloads}
\end{table}

In Wasm variants the response body passes through a trivial Wasm transform
(prepend \texttt{"wasm:"}) to isolate invocation mechanism overhead from
application logic cost. The Wasm module (\texttt{gateway\_wasm}) has zero
dependencies and targets \texttt{wasm32-wasip1}.

\subsection{Benchmark Methodology}
\label{sec:methodology}

\paragraph{Cold start.}
Measured with \texttt{hyperfine --warmup~0 --runs~20}. Each iteration:
\begin{enumerate}
  \item Kill any stale listener on port 18081.
  \item Spawn the gateway process in the background.
  \item Poll \texttt{/health} (up to 600 attempts at 10\,ms intervals).
  \item Fire one \texttt{curl} request to \texttt{/}.
  \item \texttt{kill -9} the process.
\end{enumerate}
Three benchmark repeats yield $N=60$ samples per variant.

\paragraph{Warm latency.}
Measured with \texttt{hyperfine --warmup~20 --runs~300}. The gateway is
started once and kept alive. Each iteration runs
\texttt{curl -fsS http://127.0.0.1:18081/}. The measurement includes
\texttt{curl} process startup overhead ($\approx$\SI{8}{\milli\second}),
so absolute values are inflated; \emph{relative} differences between variants
are the meaningful signal.

\paragraph{Throughput.}
Measured with \texttt{wrk} (4~threads) at seven concurrency levels:
10, 50, 100, 200, 400, 800, 1200 connections. Each run lasts
\SI{30}{\second}. A Python \texttt{psutil}-based sampler records RSS and CPU
at \SI{200}{\milli\second} intervals throughout.

\paragraph{Data pipeline.}
\texttt{scripts/bench\_all.sh} orchestrates all three benchmark types with
configurable repeats. Raw data are written to timestamped files in
\texttt{results/}. Summary statistics are computed into
\texttt{results/summary/} (percentile CSVs) and
\texttt{results/aggregated/throughput.csv}. Plots are generated in
\texttt{results/plots/}. A machine-environment snapshot is captured in
\texttt{results/meta/}.

%% ================================================================
\section{Implementation}
\label{sec:implementation}

\subsection{Gateway Architecture}

The project is a Rust workspace with three crates:

\begin{itemize}
  \item \textbf{\texttt{gateway\_native}} --- single-threaded, blocking TCP
    gateway. Handles all four workloads directly using
    \texttt{std::net::TcpStream}. No external dependencies at runtime.
  \item \textbf{\texttt{gateway\_host}} --- same TCP gateway, but delegates a
    response-body transform to a Wasm module. The actual compute (SHA-256) and
    network I/O (proxy) occur in the host; only the response body passes
    through the Wasm boundary. Supports three runtime modes selected via
    \texttt{WASM\_RUNTIME}: \texttt{wasmedge} (CLI), \texttt{wasmtime} (CLI),
    \texttt{wasmtime\_embedded} (in-process).
  \item \textbf{\texttt{gateway\_wasm}} --- minimal WASI module: reads stdin,
    prepends \texttt{"wasm:"}, writes to stdout.
\end{itemize}

\paragraph{No async.}
All gateway code is deliberately single-threaded with blocking I/O and
explicit read/write timeouts. This eliminates confounding factors from async
runtime scheduling (e.g., Tokio) and keeps the comparison fair across all
variants.

\subsection{Embedded Wasmtime Caching}

The \texttt{wasmtime\_embedded} variant compiles the Wasm module once at first
use and caches the \texttt{Engine}~+ \texttt{Module} pair in a
process-global \texttt{Lazy<RwLock<HashMap>>}. Each subsequent request allocates
a fresh \texttt{Store} and WASI context (\texttt{MemoryInputPipe} /
\texttt{MemoryOutputPipe}), instantiates the module, calls \texttt{\_start},
and reads the output pipe. This amortises compilation cost across all requests
while maintaining per-request isolation.

\subsection{Benchmark Scripts}

\begin{itemize}
  \item \texttt{scripts/bench\_cold\_start.sh} --- cold-start measurement.
  \item \texttt{scripts/bench\_warm\_latency.sh} --- warm single-request
    latency.
  \item \texttt{scripts/bench\_throughput.sh} --- throughput with resource
    sampling.
  \item \texttt{scripts/bench\_all.sh} --- orchestrator; captures environment
    snapshot, runs all benchmarks with configurable repeats.
  \item \texttt{scripts/run\_native\_local.sh},
    \texttt{scripts/run\_docker.sh},
    \texttt{scripts/run\_wasm\_host\_local.sh} --- per-variant launchers.
\end{itemize}

\subsection{Developments Achieved and Challenges}

\begin{enumerate}
  \item \textbf{Fully automated pipeline}: a single
    \texttt{scripts/bench\_all.sh} invocation builds all binaries, runs all
    three benchmark suites across all five variants, computes summary
    statistics, and generates plots.
  \item \textbf{Cross-platform port management}: scripts implement six
    detection methods (\texttt{lsof}, \texttt{fuser}, \texttt{ss},
    \texttt{nc}, \texttt{/dev/tcp}, Python \texttt{/proc/net/tcp}) for
    portable process cleanup.
  \item \textbf{Resource sampler}: a continuous \texttt{psutil}-based sampler
    at \SI{200}{\milli\second} intervals is sliced by timestamp window per
    \texttt{wrk} run.
  \item \textbf{Docker network auto-detection}: \texttt{scripts/run\_docker.sh}
    detects the Docker Compose network so the containerised gateway resolves
    \texttt{upstream} by hostname.
  \item \textbf{Challenge --- accept-queue saturation}: single-threaded
    \texttt{accept()} causes throughput instability at $>$200 connections for
    \texttt{native\_local}. This is a testbed artefact, not a runtime
    limitation.
  \item \textbf{Challenge --- sampler resolution}: the \SI{200}{\milli\second}
    sampling interval is too coarse to capture the RSS and CPU of CLI
    subprocess Wasm runtimes that live for only a few milliseconds per request.
\end{enumerate}

%% ================================================================
\section{Results}
\label{sec:results}

All numeric values below are taken directly from the CSV files listed in the
source column. No values are rounded beyond the precision present in those
files.

%% ----------------------------------------------------------------
\subsection{Cold-Start Latency}
\label{sec:cold-start}

Cold start measures the wall-clock time from \texttt{exec} of the gateway
binary to the first successful HTTP~200 response. Each variant was measured
20~times per repeat, with 3~repeats, yielding $N=60$ samples per variant.

\begin{table}[ht]
\centering
\begin{tabular}{lrrrr}
\toprule
\textbf{Variant} & \textbf{p50 (ms)} & \textbf{p90 (ms)} & \textbf{p99 (ms)} & $N$ \\
\midrule
\texttt{native\_local}           & 176.36 & 192.18 & 202.64 & 60 \\
\texttt{wasm\_host\_wasmtime}    & 190.29 & 207.09 & 214.74 & 60 \\
\texttt{wasm\_host\_cli}         & 203.49 & 215.52 & 231.36 & 60 \\
\texttt{wasm\_host\_wasmtime\_embedded} & 232.58 & 250.30 & 258.22 & 60 \\
\texttt{native\_docker}          & 3143.39 & 4426.92 & 5499.42 & 60 \\
\bottomrule
\end{tabular}
\caption{Cold-start latency percentiles.
  Source: \texttt{results/summary/cold\_start\_percentiles.csv}.}
\label{tab:cold-start}
\end{table}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{cold_start_median_p90.png}
\caption{Cold-start latency (p50 and p90) by variant.
  Source: \texttt{results/plots/cold\_start\_median\_p90.png}.}
\label{fig:cold-start}
\end{figure}

\paragraph{Interpretation.}
In this testbed, all non-Docker variants start in under \SI{260}{\milli\second}
at the p99 level. The native baseline is \SI{176.36}{\milli\second} (p50).
The two CLI Wasm variants add \SI{13.93}{\milli\second} (wasmtime) and
\SI{27.13}{\milli\second} (wasmedge) respectively. The embedded Wasmtime
variant is the slowest non-Docker starter at \SI{232.58}{\milli\second} (p50)
because its first invocation includes one-time Wasm module compilation.

Docker cold start is an order of magnitude higher at \SI{3143.39}{\milli\second}
(p50), with high variance (p99 at \SI{5499.42}{\milli\second}). This includes
container-image layer extraction, network-namespace creation, cgroup setup, and
overlay-filesystem mounting---costs that do not apply to bare-process or
in-process Wasm execution.

\FloatBarrier
%% ----------------------------------------------------------------
\subsection{Warm-Request Latency}
\label{sec:warm-latency}

Warm latency measures the \texttt{curl} round-trip time to a running gateway
for the \texttt{hello} workload. The gateway is started once and kept alive
across 300~measured iterations (after 20~warmup iterations).

\begin{table}[ht]
\centering
\begin{tabular}{lrrrr}
\toprule
\textbf{Variant} & \textbf{p50 (ms)} & \textbf{p90 (ms)} & \textbf{p99 (ms)} & $N$ \\
\midrule
\texttt{native\_local}           & 8.79  & 10.58 & 13.88 & 600 \\
\texttt{native\_docker}          & 9.17  & 11.08 & 14.66 & 300 \\
\texttt{wasm\_host\_wasmtime\_embedded} & 9.38  & 11.07 & 14.71 & 300 \\
\texttt{wasm\_host\_wasmtime}    & 20.40 & 22.61 & 26.54 & 300 \\
\texttt{wasm\_host\_cli}         & 26.78 & 30.11 & 33.97 & 300 \\
\bottomrule
\end{tabular}
\caption{Warm-request latency percentiles (\texttt{hello} workload, steady
  state). Source: \texttt{results/summary/warm\_latency\_percentiles.csv}.}
\label{tab:warm-latency}
\end{table}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{warm_latency_median_p90.png}
\caption{Warm-request latency (p50 and p90) by variant.
  Source: \texttt{results/plots/warm\_latency\_median\_p90.png}.}
\label{fig:warm-latency}
\end{figure}

\paragraph{Interpretation.}
The absolute values include approximately \SI{8}{\milli\second} of
\texttt{curl} process-startup overhead; therefore, only \emph{relative}
differences are meaningful.

Native local, Docker, and embedded Wasm cluster within
\SI{0.59}{\milli\second} of each other at p50 (8.79 vs 9.17 vs
\SI{9.38}{\milli\second}). This indicates that, in steady state on this
testbed, container networking overhead and in-process Wasm instantiation
cost are both negligible for a no-op handler.

The CLI Wasm variants show \SI{11.61}{\milli\second} (wasmtime) and
\SI{17.99}{\milli\second} (wasmedge) additional latency at p50 relative to
native. This overhead is entirely attributable to forking a child process and
initialising the Wasm runtime per request.

Tail latency (p99) follows the same ranking. Native local shows
\SI{13.88}{\milli\second}; the embedded variant tracks closely at
\SI{14.71}{\milli\second}; CLI variants reach \SI{26.54}{\milli\second}
and \SI{33.97}{\milli\second}.

\FloatBarrier
%% ----------------------------------------------------------------
\subsection{Throughput vs Concurrency}
\label{sec:throughput}

Throughput is measured with \texttt{wrk} (4~threads, \SI{30}{\second} per
run) at seven concurrency levels: 10, 50, 100, 200, 400, 800, and
1200~connections. Each workload~$\times$~variant~$\times$~concurrency
combination is a single \SI{30}{\second} run.

\subsubsection{Hello Workload (No-Op)}

\begin{table}[ht]
\centering
\small
\begin{tabular}{rrrrrrr}
\toprule
Conns & native\_local & native\_docker & wasm\_embedded & wasm\_wasmtime & wasm\_cli \\
\midrule
10   & 19\,868 & 6\,453 & 3\,476 & 101 & 58 \\
50   & 21\,988 & 8\,044 & 3\,488 & 101 & 57 \\
100  & 22\,745 & 8\,696 & 3\,569 & 100 & 57 \\
200  & 22\,442 & 8\,784 & 1\,406 & 98  & 55 \\
400  & 4\,566  & 9\,033 & 1\,380 & 96  & 15 \\
800  & 6\,647  & 9\,114 & 1\,323 & 95  & 54 \\
1200 & 5\,618  & 8\,898 & 2\,230 & 96  & 12 \\
\bottomrule
\end{tabular}
\caption{Hello workload throughput (RPS).
  Source: \texttt{results/summary/throughput\_summary.csv},
  rows where \texttt{workload=hello}.}
\label{tab:throughput-hello}
\end{table}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{throughput_hello.png}
\caption{Hello workload: throughput vs concurrency.
  Source: \texttt{results/plots/throughput\_hello.png}.}
\label{fig:throughput-hello}
\end{figure}

\paragraph{Interpretation.}
Native local peaks at 22\,745~RPS at 100~connections, then drops sharply at
400+ connections. This degradation is an artefact of the single-threaded
\texttt{accept()} queue saturating on this 4-core machine: when more
connections arrive than the gateway can drain in one thread, queueing delays
dominate. Docker stabilises around 8\,700--9\,100~RPS and does \emph{not}
exhibit the same drop, likely because the container's network namespace
introduces a pacing effect that prevents accept-queue saturation.

Embedded Wasm achieves 3\,569~RPS at 100~connections (15.7\% of native peak),
with per-request \texttt{Store} instantiation as the bottleneck. The CLI
variants are capped at $\approx$100~RPS (wasmtime) and $\approx$57~RPS
(wasmedge), entirely limited by the time to fork and initialise a child
process per request.

\subsubsection{Compute Workload (CPU-Bound)}

\begin{table}[ht]
\centering
\small
\begin{tabular}{rrrrrrr}
\toprule
Conns & native\_local & native\_docker & wasm\_embedded & wasm\_wasmtime & wasm\_cli \\
\midrule
10   & 23  & 135 & 131 & 13  & 11 \\
50   & 136 & 134 & 132 & 56  & 40 \\
100  & 135 & 133 & 130 & 55  & 39 \\
200  & 133 & 132 & 87  & 53  & 37 \\
400  & 132 & 107 & 125 & 52  & 36 \\
800  & 132 & 130 & 129 & 14  & 24 \\
1200 & 132 & 57  &  95 & 53  & 23 \\
\bottomrule
\end{tabular}
\caption{Compute workload throughput (RPS).
  Source: \texttt{results/summary/throughput\_summary.csv},
  rows where \texttt{workload=compute}.}
\label{tab:throughput-compute}
\end{table}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{throughput_compute.png}
\caption{Compute workload: throughput vs concurrency.
  Source: \texttt{results/plots/throughput\_compute.png}.}
\label{fig:throughput-compute}
\end{figure}

\paragraph{Interpretation.}
At 100~connections, native (135~RPS), Docker (133~RPS), and embedded Wasm
(130~RPS) converge within 3.7\% of each other. The 20\,000-iteration SHA-256
chain ($\approx$\SI{7.3}{\milli\second} per request) dominates execution
time, making the Wasm instantiation overhead negligible. This confirms
Hypothesis~5: for CPU-bound workloads on this testbed, the execution model
overhead amortises.

CLI variants remain lower (55 and 39~RPS at 100~connections) because
process-spawn cost adds to each request's computation time.

The anomalous result at \{native\_local, compute, 10~connections\} (23~RPS vs
135~RPS at 50) is likely a warm-up artefact: with only 10 connections the
single-threaded gateway may not reach full CPU utilisation within the
measurement window.

\FloatBarrier
%% ----------------------------------------------------------------
\subsection{Resource Footprint and Efficiency}
\label{sec:resources}

Resource consumption is sampled continuously during throughput runs at
\SI{200}{\milli\second} intervals.

\begin{table}[ht]
\centering
\begin{tabular}{lrrr}
\toprule
\textbf{Variant} & \textbf{RSS (KB)} & \textbf{CPU avg (\%)} & \textbf{CPU/1k RPS} \\
\midrule
\texttt{native\_local}           & 788     & 90.31 & 3.97 \\
\texttt{native\_docker}          & 1\,180  & 41.67 & 4.79 \\
\texttt{wasm\_embedded}          & 19\,760 & 99.58 & 27.90 \\
\texttt{wasm\_wasmtime}          & 4\,836  & 2.83  & 28.39 \\
\texttt{wasm\_cli}               & 4\,692  & 2.03  & 35.88 \\
\bottomrule
\end{tabular}
\caption{Resource footprint during \texttt{hello} workload at 100~connections.
  Source: \texttt{results/summary/throughput\_summary.csv},
  rows where \texttt{workload=hello}, \texttt{conns=100}.
  CPU/1k RPS = \texttt{cpu\_per\_1k\_rps} column.}
\label{tab:resource}
\end{table}

\paragraph{Memory.}
Native local uses only \SI{788}{\kilo\byte}. Docker adds
$\approx$\SI{392}{\kilo\byte} for container metadata (1\,180~KB total).
The CLI Wasm variants use $\approx$\SI{4.7}{\mega\byte} (host process only;
the short-lived child processes are not captured by the \SI{200}{\milli\second}
sampler). Embedded Wasm uses \SI{19.3}{\mega\byte}, reflecting the compiled
Wasm module, Wasmtime engine, and per-request \texttt{Store} allocations kept
in process memory.

\paragraph{CPU efficiency.}
CPU per 1\,000~RPS normalises CPU usage by throughput, allowing cross-variant
comparison of how much CPU is ``spent'' per unit of useful work.
Native local and Docker are the most CPU-efficient at 3.97 and 4.79
respectively. Embedded Wasm is 7$\times$ less efficient at 27.90 because each
request incurs Wasm module instantiation and WASI pipe I/O. CLI variants show
low \emph{host-process} CPU (2--3\%) because the actual work occurs in forked
child processes not tracked by the host-process sampler.

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{rss_hello.png}
\caption{Gateway RSS during hello workload by variant and concurrency.
  Source: \texttt{results/plots/rss\_hello.png}.}
\label{fig:rss-hello}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{efficiency_hello.png}
\caption{CPU efficiency (CPU\% per 1k RPS) for hello workload.
  Source: \texttt{results/plots/efficiency\_hello.png}.}
\label{fig:efficiency-hello}
\end{figure}

\FloatBarrier
%% ================================================================
\section{Discussion}
\label{sec:discussion}

\paragraph{Cold start.}
All Wasm variants start within \SI{56}{\milli\second} of the native baseline
at the p50 level. Docker cold start is 17.8$\times$ slower than native,
dominated by container-image and network-namespace initialisation. For
latency-sensitive cold-start scenarios on this testbed, any of the Wasm
variants outperforms Docker by an order of magnitude.

\paragraph{Warm latency.}
In steady state, Docker and embedded Wasm add less than
\SI{1}{\milli\second} over native at p50. The differences are within
measurement noise given the $\approx$\SI{8}{\milli\second} curl overhead
floor. CLI Wasm adds 12--18~ms per request due to process-creation cost.
This confirms that in-process Wasm instantiation is a viable low-overhead
mechanism for per-request isolation on this testbed.

\paragraph{Throughput.}
The hello workload reveals a 6.4$\times$ gap between native and embedded Wasm
at 100~connections (22\,745 vs 3\,569~RPS). For CPU-bound work (compute at
100~connections), the gap shrinks to 3.7\% (135 vs 130~RPS) because the
computation dominates. For I/O-bound work (proxy at 100~connections),
embedded Wasm reaches 839~RPS vs 1\,138~RPS native (73.7\%). The
ratio of gateway overhead to workload cost determines whether Wasm is a
practical choice for a given scenario.

\paragraph{Resource trade-offs.}
Embedded Wasm uses 25$\times$ more memory than native (19\,760 vs
788~KB) but offers per-request sandboxing. The CPU efficiency gap
(27.9 vs 4.0 CPU\%/1k RPS for hello) reflects the per-request
instantiation cost. For compute workloads this gap narrows
(767.0 vs 738.7), again confirming that workload-dominated scenarios
amortise the overhead.

\paragraph{No universal claim.}
These results do not support a general claim that ``Wasm is faster than
Docker'' or vice versa. The performance ranking depends on the metric (cold
start favours Wasm; steady-state throughput favours native), the workload
(CPU-bound work equalises), and the platform (Linux native Docker vs
macOS Docker Desktop would yield different results).

%% ================================================================
\section{Limitations and Validity Threats}
\label{sec:limitations}

\begin{enumerate}
  \item \textbf{Loopback networking.} All communication uses
    \texttt{127.0.0.1}, eliminating real network latency and jitter. Results
    may differ on a multi-host deployment with physical or virtual NICs.

  \item \textbf{Single-host load generation.} \texttt{wrk} runs on the same
    machine as the gateway under test, competing for the same 4~CPU cores.
    At high concurrency, load-generator scheduling may interfere with gateway
    throughput.

  \item \textbf{KVM virtualisation.} The testbed is a KVM virtual machine.
    CPU scheduling and memory allocation pass through the hypervisor, which
    may add latency variance not present on bare metal.

  \item \textbf{Single-threaded gateway.} The blocking, single-threaded
    design limits maximum throughput and causes accept-queue saturation at
    high concurrency. This is a deliberate design choice for fairness, but it
    means results are not directly transferable to production async gateways.

  \item \textbf{Curl overhead in warm latency.} Each warm-latency iteration
    spawns a \texttt{curl} process ($\approx$\SI{8}{\milli\second}
    overhead), inflating absolute values. Only relative comparisons are
    meaningful.

  \item \textbf{Resource sampler resolution.} The \SI{200}{\milli\second}
    sampling interval cannot capture the RSS or CPU of CLI subprocess Wasm
    runtimes, which live for only a few milliseconds per request. The
    reported host-process CPU (2--3\%) underestimates total system cost for
    CLI variants.

  \item \textbf{Sample counts.} Cold start: $N=60$; warm latency:
    $N=300$--600; throughput: single \SI{30}{\second} run per configuration.
    These counts may not capture rare tail-latency events or account for
    long-term drift.

  \item \textbf{Trivial Wasm module.} The transform module prepends a string.
    A more complex Wasm plugin with memory allocation, I/O, or multi-function
    calls would increase per-request overhead.

  \item \textbf{Wasmtime JIT caching.} The embedded variant compiles the
    module once and reuses compiled code. Cold start for the embedded variant
    therefore includes this compilation, but subsequent requests benefit from
    caching. A scenario requiring frequent module reloads would show different
    characteristics.

  \item \textbf{Docker on Linux vs macOS.} The mid-term report used Docker
    Desktop on macOS (which adds a Linux VM layer). This final testbed uses
    native Linux Docker, so Docker overhead here is lower than on macOS.
    Results should not be compared directly across platforms.
\end{enumerate}

%% ================================================================
\section{Future Work}
\label{sec:future}

\begin{itemize}
  \item Run benchmarks on bare-metal hardware to eliminate hypervisor
    variability.
  \item Replace \texttt{curl}-based warm-latency measurement with a
    persistent-connection client to remove process-spawn overhead from the
    measurement.
  \item Add a multi-threaded gateway variant to test scalability beyond
    single-thread bottlenecks.
  \item Benchmark a non-trivial Wasm plugin (e.g., JSON transformation,
    request routing with regex) to evaluate overhead with realistic
    application logic.
  \item Compare Wasmtime's ahead-of-time (AOT) compilation mode against the
    current JIT-on-first-use approach.
  \item Introduce a Firecracker or gVisor baseline for lightweight VM
    comparison.
  \item Increase sample counts and add multiple-run throughput measurements
    to improve statistical confidence.
\end{itemize}

%% ================================================================
\section{Conclusion}
\label{sec:conclusion}

This project delivers a reproducible benchmark suite for comparing native,
containerised, and WebAssembly-based HTTP gateway middleware on a Linux KVM
testbed with 4~CPU cores and \SI{15}{\gibi\byte} RAM.

The principal findings, \emph{scoped to this testbed}, are:

\begin{enumerate}
  \item \textbf{Cold start:} All Wasm variants add 14--56~ms over the
    native baseline (176~ms p50). Docker is 17.8$\times$ slower at
    3\,143~ms p50.
  \item \textbf{Warm latency:} Docker and embedded Wasm are within
    \SI{1}{\milli\second} of native in steady state. CLI Wasm adds
    12--18~ms per request due to process spawning.
  \item \textbf{Throughput (no-op):} Native peaks at 22\,745~RPS; Docker at
    9\,114; embedded Wasm at 3\,569; CLI variants below 101~RPS.
  \item \textbf{Throughput (CPU-bound):} Native, Docker, and embedded Wasm
    converge at $\approx$130~RPS---the SHA-256 computation dominates,
    making runtime overhead negligible.
  \item \textbf{Resources:} Embedded Wasm uses 25$\times$
    more memory than native (19.3~MB vs 0.8~MB) and 7$\times$ more CPU per
    unit of throughput for no-op work.
\end{enumerate}

No universal ``Wasm is faster than Docker'' claim is supported. The
performance trade-off depends on the workload profile: for CPU- or I/O-bound
tasks where computation dominates gateway overhead, embedded Wasm provides
lightweight per-request isolation at near-native speed. For routing-only
workloads, native execution remains an order of magnitude faster. CLI-based
Wasm invocation measures process-spawn overhead and is not representative of
production Wasm deployment performance.

%% ================================================================
\section*{References}
\begin{itemize}
  \item Wasmtime: \url{https://github.com/bytecodealliance/wasmtime}
  \item WasmEdge: \url{https://github.com/WasmEdge/WasmEdge}
  \item Docker: \url{https://www.docker.com}
  \item wrk: \url{https://github.com/wg/wrk}
  \item hyperfine: \url{https://github.com/sharkdp/hyperfine}
\end{itemize}

%% ================================================================
\appendix
\section{Additional Throughput Results}
\label{app:throughput}

\subsection{State Workload}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{throughput_state.png}
\caption{State workload: throughput vs concurrency.
  Source: \texttt{results/plots/throughput\_state.png}.}
\label{fig:throughput-state}
\end{figure}

\subsection{Proxy Workload}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{throughput_proxy.png}
\caption{Proxy workload: throughput vs concurrency.
  Source: \texttt{results/plots/throughput\_proxy.png}.}
\label{fig:throughput-proxy}
\end{figure}

\section{Latency vs Concurrency}
\label{app:latency}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{latency_hello.png}
\caption{Hello workload: mean latency vs concurrency.
  Source: \texttt{results/plots/latency\_hello.png}.}
\label{fig:latency-hello}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{latency_compute.png}
\caption{Compute workload: mean latency vs concurrency.
  Source: \texttt{results/plots/latency\_compute.png}.}
\label{fig:latency-compute}
\end{figure}

\section{Resource Profiles by Workload}
\label{app:resources}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{rss_compute.png}
\caption{RSS during compute workload.
  Source: \texttt{results/plots/rss\_compute.png}.}
\label{fig:rss-compute}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{efficiency_compute.png}
\caption{CPU efficiency during compute workload.
  Source: \texttt{results/plots/efficiency\_compute.png}.}
\label{fig:efficiency-compute}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{rss_proxy.png}
\caption{RSS during proxy workload.
  Source: \texttt{results/plots/rss\_proxy.png}.}
\label{fig:rss-proxy}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{efficiency_proxy.png}
\caption{CPU efficiency during proxy workload.
  Source: \texttt{results/plots/efficiency\_proxy.png}.}
\label{fig:efficiency-proxy}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{rss_state.png}
\caption{RSS during state workload.
  Source: \texttt{results/plots/rss\_state.png}.}
\label{fig:rss-state}
\end{figure}

\begin{figure}[ht]
\centering
\includegraphics[width=0.85\linewidth]{efficiency_state.png}
\caption{CPU efficiency during state workload.
  Source: \texttt{results/plots/efficiency\_state.png}.}
\label{fig:efficiency-state}
\end{figure}

\section{Full Throughput Data Tables}
\label{app:tables}

\subsection{Proxy Workload (RPS)}

\begin{table}[ht]
\centering
\small
\begin{tabular}{rrrrrr}
\toprule
Conns & native\_local & native\_docker & wasm\_embedded & wasm\_wasmtime & wasm\_cli \\
\midrule
10   & 242   & 1\,028 & 130 & 19  & 51 \\
50   & 1\,174 & 1\,040 & 846 & 90  & 54 \\
100  & 1\,138 & 1\,029 & 839 & 88  & 53 \\
200  & 863   & 632   & 536 & 73  & 35 \\
400  & 572   & 780   & 490 & 55  & 14 \\
800  & 720   & 432   & 238 & 55  & 36 \\
1200 & 477   & 465   & 522 & 70  & 26 \\
\bottomrule
\end{tabular}
\caption{Proxy workload throughput (RPS).
  Source: \texttt{results/summary/throughput\_summary.csv},
  rows where \texttt{workload=proxy}.}
\label{tab:throughput-proxy}
\end{table}

\subsection{State Workload (RPS)}

\begin{table}[ht]
\centering
\small
\begin{tabular}{rrrrrr}
\toprule
Conns & native\_local & native\_docker & wasm\_embedded & wasm\_wasmtime & wasm\_cli \\
\midrule
10   & 3\,263  & 146   & 801   & 99  & 14 \\
50   & 21\,789 & 7\,133 & 3\,511 & 101 & 58 \\
100  & 23\,000 & 8\,761 & 3\,542 & 100 & 56 \\
200  & 21\,538 & 8\,602 & 2\,139 & 98  & 54 \\
400  & 8\,294  & 9\,136 & 2\,200 & 97  & 15 \\
800  & 6\,080  & 9\,103 & 1\,278 & 60  & 53 \\
1200 & 7\,723  & 8\,916 & 1\,693 & 78  & 54 \\
\bottomrule
\end{tabular}
\caption{State workload throughput (RPS).
  Source: \texttt{results/summary/throughput\_summary.csv},
  rows where \texttt{workload=state}.}
\label{tab:throughput-state}
\end{table}

\label{fin}

\end{document}
