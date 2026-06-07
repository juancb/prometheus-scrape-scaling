#!/usr/bin/env bash
# ramp.sh — drive run-bench.sh across an increasing series ladder to find the
# point where a 1s scrape interval can no longer be sustained (the failure cliff),
# and aggregate every run's summary into one comparison CSV.
#
# Usage:
#   PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 bash scripts/ramp.sh
#   PROM_BIN=.../prometheus PROM_VERSION=v3.12.0 \
#     SERIES_LIST="100000 1000000 5000000 10000000 20000000" DURATION=20 \
#     bash scripts/ramp.sh
#
# Env:
#   SERIES_LIST   space-separated ladder (default below)
#   DURATION      per-run sample window seconds (default 20)
#   STOP_ON_FAIL  stop after first non-sustained/failed run (default 1)
#   (plus everything run-bench.sh accepts)
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

: "${PROM_BIN:?set PROM_BIN}"
: "${PROM_VERSION:?set PROM_VERSION}"
SERIES_LIST="${SERIES_LIST:-100000 500000 1000000 2000000 5000000 10000000 20000000}"
DURATION="${DURATION:-20}"
STOP_ON_FAIL="${STOP_ON_FAIL:-1}"

TS="$(date +%Y%m%d-%H%M%S)"
AGG="results/ramp__${PROM_VERSION}__${TS}.csv"
echo "series,sustained_1s,creation_reached,cpu_cores_used,cpu_s_per_million_series,creation_scrape_s,steady_cpu_cores,steady_cpu_s_per_million,steady_scrape_s,ingest_series_per_s,peak_head_series,peak_rss_gib,max_scrape_s,fail_reason" >"$AGG"
echo "==> ramp $PROM_VERSION  ladder: $SERIES_LIST  -> $AGG"

for S in $SERIES_LIST; do
  echo "==================== series=$S ===================="
  set +e
  SERIES="$S" DURATION="$DURATION" PROM_BIN="$PROM_BIN" PROM_VERSION="$PROM_VERSION" \
    bash scripts/run-bench.sh
  rc=$?
  set -e

  # locate the newest summary.json for this version+series
  J="$(ls -t results/${PROM_VERSION}__series-${S}__*/summary.json 2>/dev/null | head -1)"
  if [[ -z "$J" ]]; then
    echo "$S,NO_SUMMARY,,,,,,,run_failed_rc=$rc" >>"$AGG"
    [[ "$STOP_ON_FAIL" == 1 ]] && { echo "!! no summary, stopping"; break; }
    continue
  fi

  # One value per line into an array so EMPTY fields are preserved (read with a
  # whitespace IFS would collapse consecutive empties and misalign the row).
  mapfile -t F < <(
    jq -r '[(.measured.sustained_1s//false),
            (.measured.creation_reached//false),
            (.measured.cpu_cores_used//"" ),
            (.measured.cpu_seconds_per_million_series//""),
            (.measured.creation_scrape_duration_s//""),
            (.measured.steady_cpu_cores//""),
            (.measured.steady_cpu_s_per_million//""),
            (.measured.steady_scrape_duration_s//""),
            (.measured.ingest_series_per_s//""),
            (.measured.peak_head_series//""),
            (.measured.peak_rss_gib//""),
            (.measured.max_scrape_duration_s//""),
            (.meta.fail_reason//"")] | .[] | tostring' "$J")
  echo "$S,${F[0]},${F[1]},${F[2]},${F[3]},${F[4]},${F[5]},${F[6]},${F[7]},${F[8]},${F[9]},${F[10]},${F[11]},${F[12]}" >>"$AGG"
  sustained="${F[0]}"; sdur="${F[4]}"; fail="${F[12]}"

  # Two distinct cliffs:
  #   soft cliff  = can't sustain 1s scrapes (scrape > 1s or up<1) -> note, keep climbing
  #   hard cliff  = Prometheus process exited (OOM/crash)          -> stop the ramp
  if [[ "$sustained" != "true" ]]; then
    echo "!! soft cliff: series=$S did NOT sustain 1s scrapes (max_scrape=${sdur}s up>=? sustained=$sustained)"
  fi
  if [[ -n "$fail" ]]; then
    echo "!! HARD cliff: series=$S -> $fail (likely OOM)"
    [[ "$STOP_ON_FAIL" == 1 ]] && { echo "==> stopping ramp at hard failure series=$S"; break; }
  fi
done

echo
echo "==> ramp complete: $AGG"
column -s, -t "$AGG"
