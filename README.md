# Prometheus Ingest Benchmark

Measures **how much CPU one Prometheus server spends on scrape ingest**, how its
throughput scales with cores toward a **10M samples/s** target, and how it behaves
at that operating point over a full TSDB compaction cycle. Runs entirely on the host
it benchmarks.

## Reports

Three self-contained write-ups, each with its own data and rendered plots:

| Report | Box | Question answered |
|---|---|---|
| **[RESULTS.md](RESULTS.md)** | Intel Xeon, 16 vCPU | Ingest to failure: peak rate (**≈7.7M/s, CPU-bound**), the cardinality cliff, and the OOM ceiling. |
| **[results/scale-cores…/REPORT.md](results/scale-cores__v3.12.0__20260607-081659/REPORT.md)** | AMD EPYC, 64 vCPU | How ingest scales with cores — **~16 cores sustains 10M/s** (+ [FAQ](results/scale-cores__v3.12.0__20260607-081659/FAQ.md)). |
| **[results/endurance…/REPORT.md](results/endurance__v3.12.0__20260607-181804/REPORT.md)** | AMD EPYC, 64 vCPU | 10M/s endurance: the **first 2h compaction stalls & nearly OOMs** at 16 cores. |

## Hosts under test

| | Cardinality-to-failure (RESULTS.md) | Core-scaling & endurance (EPYC reports) |
|---|---|---|
| Host | `ubuntu-m-16vcpu-128gb-sfo3` | AWS EPYC instance |
| CPU | Intel Xeon Gold 6248, **16 vCPU** (1 thread/core) | AMD EPYC 7R32, **64 vCPU** (32 cores × 2 SMT) |
| RAM | **128 GB** (no swap) | **124 GiB** (no swap) |
| Disk | 387 GB volume | instance-store **NVMe** (`/mnt/tsdb`) |

## Architecture (in Prometheus terms)

```
                 cores 0–15 (shared)
   ┌───────────────────────────────────────────────┐
   │  ONE Prometheus server   GOMAXPROCS=16         │
   │   scrape ─▶ parse ─▶ append into TSDB head     │
   │                                                 │
   │  scrapes N targets concurrently (1 goroutine    │
   │  per target) every scrape_interval              │
   └───────────────────────────────────────────────┘
        ▲ scrapes                       measured via Prometheus' OWN metrics:
        │                                 process_cpu_seconds_total      (ingest CPU)
   ┌────┴───────────────────────────┐     prometheus_tsdb_head_series    (cardinality)
   │  N synthetic exporters         │     ..head_samples_appended_total  (ingest progress)
   │  (metricgen), one per TARGET   │     process_resident_memory_bytes  (RSS → OOM)
   │  :9100,:9101,…  K series each   │
   │  precomputed text → ~0 CPU      │
   └────────────────────────────────┘
```

- **Exporter** (`metricgen`) — serves `/metrics` with `K` synthetic series
  (`synthetic_metric{id="…"} 1`). It precomputes the whole payload once and resends
  the same bytes each scrape, so its CPU is negligible — any CPU Prometheus burns is
  ingest. It can grow its cardinality at runtime via `GET /resize?series=N`.
- **Target** — one exporter `host:port` in Prometheus' `scrape_configs`. With **N
  targets**, total head series = **N × K** (Prometheus stamps each target with a
  distinct `instance` label, so series stay globally unique).
- **Ingest** — the scrape→parse→append pipeline (there is no separate "ingester" in
  single-binary Prometheus). CPU for ingest is read from Prometheus'
  `process_cpu_seconds_total`, so the measurement is isolated even when exporters
  share the same cores.

**Parallelism:** Prometheus scrapes each target on its own goroutine, and a single
scrape's parse+append is ~serial. So the cores it can use for ingest ≈
**min(targets, cores)** — you need **N targets ≥ cores** to saturate the box.

## What's measured

Headline number: **CPU-seconds per 1,000,000 samples ingested** (core-count
independent), plus **cores used**, **worst-case scrape duration across targets**
(the 3rd plot axis), **peak head series**, and **peak RSS** (→ the OOM point).

Memory rule of thumb measured here: **~1.4 KB of RSS per head series** → a 128 GB
box OOMs somewhere around **80–90M series**.

## Binaries compared

- **apt 2.45.3** — `/usr/bin/prometheus` (installed via apt).
- **v3.12.0** — `/home/jbran/prometheus-3.12.0.linux-amd64/prometheus` (tarball).

## Modes / scripts

| Script | Feeds | What it does |
|---|---|---|
| `scripts/grow-to-oom.sh` | RESULTS.md | **One** long-lived Prometheus, **fixed `TARGETS` (= cores)**, grows each target's series via `/resize` until **OOM**. Records steady CPU + worst-case scrape + RSS at each plateau. The "test to failure" runner. |
| `scripts/rate-max.sh` | RESULTS.md | Finds **peak sustained ingest rate** (samples/s actually appended). `TARGETS > cores`; at each cardinality it auto-tightens the scrape interval toward the back-to-back (CPU-bound) regime and records max rate, CPU util, and RSS. |
| `scripts/plot.py` | RESULTS.md | 3D plot (series × CPU × scrape time) + 2D projections from a growth CSV; OOM marked. |
| `scripts/plot-rate.py` | RESULTS.md | Rate-max plots: ingest rate / CPU util / RSS vs cardinality + a 3D (rate × CPU × memory). |
| `scripts/scale-cores.sh` | scale-cores report | Strong-scaling sweep: holds per-core cardinality constant, varies `GOMAXPROCS`+`taskset` core count, measures peak ingest with replicates. A closed-loop controller tightens the interval to hold the box saturated. |
| `scripts/analyze-scale.py` | scale-cores report | Saturation-aware analysis of `scale.csv` → `scale-summary.csv` + the two-panel capacity/efficiency plot with 95% CIs. |
| `scripts/endurance-compaction.sh` | endurance report | Runs the 10M/s operating point continuously on NVMe and samples TSDB/CPU/RSS/scrape every 10s across the first **2h-block head compaction**. |
| `scripts/analyze-endurance.py` | endurance report | Detects compaction onset (head span ≥ 3h) and renders the 4-panel endurance time series. |

Go is at `/usr/local/go/bin` (1.26.x).

### Examples

```bash
# Grow to OOM: 16 targets across 16 cores, +16M series/step
TARGETS=16 CORES=0-15 K_START=1000000 K_STEP=1000000 INTERVAL=30s \
  PROM_BIN=/home/jbran/prometheus-3.12.0.linux-amd64/prometheus PROM_VERSION=v3.12.0 \
  bash scripts/grow-to-oom.sh

# Peak ingest rate sweep
bash scripts/rate-max.sh

# Core-scaling toward 10M/s (EPYC), then analyze
bash scripts/scale-cores.sh && python3 scripts/analyze-scale.py

# 10M/s endurance through the first 2h compaction (EPYC), then analyze
bash scripts/endurance-compaction.sh && python3 scripts/analyze-endurance.py
```

## Key findings

See the three **[Reports](#reports)** above: `RESULTS.md` (cardinality-to-failure &
peak rate on 16 vCPU), the **scale-cores** report (core-scaling to 10M/s on 64 vCPU),
and the **endurance** report (10M/s across the first 2h compaction).
