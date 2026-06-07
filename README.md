# Prometheus Ingest Benchmark

Measures **how much CPU one Prometheus server spends on scrape ingest** as series
cardinality climbs toward failure. Runs entirely on the host it benchmarks.

## Host under test

| | |
|---|---|
| Host | `ubuntu-m-16vcpu-128gb-sfo3` (Ubuntu 24.04.3) |
| CPU | Intel Xeon Gold 6248 @ 2.50GHz, **16 vCPU** (1 thread/core) |
| RAM | **128 GB** (no swap) |
| Disk | 387 GB volume, ~381 GB free |

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

| Script | What it does |
|---|---|
| `scripts/run-bench.sh` | One cold run: starts exporters + a fresh Prometheus, samples 1/s, writes `samples.csv` + `summary.{json,txt}`. Knobs: `SERIES` (total), `TARGETS`, `AUTO_INTERVAL`, `INTERVAL`, `DURATION`, `PROM_CORES`/`GEN_CORES`. |
| `scripts/ramp.sh` | Cold-restart ladder over `SERIES_LIST`; aggregates each run's summary to one CSV. Good for the per-cardinality curve and the **strict-1s scrape-timeout wall**. |
| `scripts/grow-to-oom.sh` | **One** long-lived Prometheus, **fixed `TARGETS` (= cores)**, grows each target's series via `/resize` until **OOM**. Records steady CPU + worst-case scrape + RSS at each plateau. This is the "test to failure" runner. |
| `scripts/rate-max.sh` | Finds **peak sustained ingest rate** (samples/s actually appended). `TARGETS > cores`; at each cardinality it auto-tightens the scrape interval toward the back-to-back (CPU-bound) regime and records the max rate, CPU util, and RSS. Answers "how fast can it ingest?" |
| `scripts/plot.py` | 3D plot (series × CPU × scrape time) + 2D projections from a ramp/growth CSV; OOM marked. |
| `scripts/plot-rate.py` | Rate-max plots: ingest rate / CPU util / RSS vs cardinality + a 3D (rate × CPU × memory). |

Go is at `/usr/local/go/bin` (1.26.x).

### Examples

```bash
# Cold single run (validate harness)
PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 SERIES=100000 DURATION=25 \
  bash scripts/run-bench.sh

# Strict-1s wall (single target)
PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 \
  SERIES_LIST="100000 200000 300000 400000 500000" DURATION=18 bash scripts/ramp.sh

# Grow to OOM: 16 targets across 16 cores, +16M series/step
TARGETS=16 CORES=0-15 K_START=1000000 K_STEP=1000000 INTERVAL=30s \
  PROM_BIN=/home/jbran/prometheus-3.12.0.linux-amd64/prometheus PROM_VERSION=v3.12.0 \
  bash scripts/grow-to-oom.sh
```

## Key findings

See **[RESULTS.md](RESULTS.md)** for the measured curves, the strict-1s wall, the
multi-target scaling, and the OOM cardinality for each binary.
