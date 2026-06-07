# Prometheus Ingest Benchmark

Measures **how much CPU Prometheus spends on scrape ingest alone** as series
cardinality climbs toward failure, on a fixed **1 second scrape interval**.
Runs entirely on the host it benchmarks (no SSH/sshfs needed — this *is* the box).

## Host under test

| | |
|---|---|
| Host | `ubuntu-m-16vcpu-128gb-sfo3` (Ubuntu 24.04.3) |
| CPU | Intel Xeon Gold 6248 @ 2.50GHz, **16 vCPU** (1 thread/core) |
| RAM | **128 GB** |
| Disk | 387 GB volume, ~381 GB free |

By default Prometheus is pinned to cores **0–7** and the load generator to cores
**8–15**, so the two never contend and measured CPU is purely Prometheus.

## What's measured

Per run, sampled once per second:

- `process_cpu_seconds_total` — authoritative Prometheus CPU (primary metric).
- `prometheus_tsdb_head_series` — series actually held in the head block.
- `prometheus_tsdb_head_samples_appended_total{type="float"}` — ingest progress.
- `process_resident_memory_bytes` — RSS.
- `up`, `scrape_duration_seconds`, `scrape_samples_scraped` for the synthetic job.

Derived in `summary.{json,txt}`:

- **CPU cores used for ingest** and **% of the cores Prometheus was given**.
- **CPU-seconds per 1,000,000 samples** — the headline efficiency number.
- **Peak head series**, **peak RSS**.
- **`sustained_1s`** verdict: did every scrape stay `up=1` *and* finish in < 1s?
  This is the failure definition — the cliff is the first series count that
  can't be scraped+ingested within the interval (or where Prometheus OOMs/crashes).

## Design: why the generator barely uses CPU

`metricgen` (Go) builds the **entire `/metrics` exposition payload once** at
startup and serves the identical byte slice on every scrape with a single
`w.Write`. There is no per-scrape formatting, so the generator's CPU is
negligible and any CPU burned is Prometheus parsing + appending + indexing.
Values are constant (one varying integer label `id` gives uniqueness); this
fully exercises the dominant ingest path.

> Note on scale: 100,000,000 series is ~3.5 GB of scrape text **per second** and
> well over 100 GB of head RAM — it will fail far below 100M on a 128 GB box.
> That's the expected "test to failure"; the ramp finds the cliff cheaply.

## Layout

```
metricgen/main.go          synthetic exporter (precomputed payload)
configs/prometheus.tmpl.yml scrape config template (interval/timeout/port substituted)
scripts/run-bench.sh        one run: start gen+prom pinned, sample 1/s, summarize
scripts/ramp.sh             run a series ladder, stop at the cliff, aggregate to CSV
results/<run-id>/           samples.csv, summary.json, summary.txt, *.log
```

## Usage

Go is at `/usr/local/go/bin` (1.26.x). A single run:

```bash
PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 \
  SERIES=100000 DURATION=25 bash scripts/run-bench.sh
```

Find the cliff for a binary (ramp + comparison CSV):

```bash
PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 bash scripts/ramp.sh
PROM_BIN=/home/jbran/prometheus-3.12.0.linux-amd64/prometheus \
  PROM_VERSION=v3.12.0 bash scripts/ramp.sh
```

### Binaries compared

- **apt 2.45.3** — `/usr/bin/prometheus` (installed via apt).
- **v3.12.0** — `/home/jbran/prometheus-3.12.0.linux-amd64/prometheus` (tarball).

## Baseline (100K series, 1s, 8 cores) — sanity check

| Binary | Sustained 1s | CPU cores | cpu-s / 1M samples | Peak RSS |
|---|---|---|---|---|
| apt 2.45.3 | ✅ | ~0.13 | ~1.26 | 0.28 GiB |
| v3.12.0 | ✅ | ~0.13 | ~1.26 | 0.31 GiB |

Both versions ingest 100K series/s for ~0.13 of a core — headroom is large, so
the ramp pushes cardinality up to find where 1s scrapes break.
