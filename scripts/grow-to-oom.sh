#!/usr/bin/env bash
# grow-to-oom.sh — drive ONE long-lived Prometheus to OOM by growing its head,
# with a FIXED set of targets (one per core) so ingest parallelism stays pinned
# to the core count the whole way.
#
# Architecture (Prometheus terms):
#   - ONE Prometheus server, GOMAXPROCS=NCORES, scraping TARGETS exporters.
#   - TARGETS synthetic exporters (metricgen), each a scrape target serving K series.
#     Total head series = TARGETS x K. Exporters are resizable: each growth step we
#     GET /resize?series=K on every exporter to raise K, so the head climbs without
#     restarting Prometheus or adding/removing targets.
#   - Exporters serve precomputed bytes (~0 CPU); ingest CPU is read from Prometheus'
#     own process_cpu_seconds_total, so the measurement stays isolated even when the
#     exporters share the same cores.
#
# At each plateau (head stops growing) it records steady-state ingest CPU, worst-case
# scrape duration across targets, head size, and RSS. The last row is the OOM point.
#
# Usage:
#   PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 bash scripts/grow-to-oom.sh
#
# Env:
#   TARGETS         number of exporters/targets (= cores to fill)   (default 16)
#   CORES           cpu set Prometheus+exporters share              (default 0-15)
#   K_START         series per target to begin with                 (default 1000000)
#   K_STEP          series per target added each growth step        (default 1000000)
#   K_MAX           safety cap on series per target                 (default 12000000)
#   INTERVAL        scrape interval == timeout                      (default 30s)
#   PROM_PORT/GEN_PORT                                              (9090 / 9100)
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

: "${PROM_BIN:?set PROM_BIN}"
: "${PROM_VERSION:?set PROM_VERSION}"
TARGETS="${TARGETS:-16}"
CORES="${CORES:-0-15}"
NCORES=$(( $(echo "$CORES" | awk -F- '{print ($2?$2:$1)-$1+1}') ))
K_START="${K_START:-1000000}"
K_STEP="${K_STEP:-1000000}"
K_MAX="${K_MAX:-12000000}"
INTERVAL="${INTERVAL:-30s}"; INTERVAL_S="${INTERVAL%s}"
PROM_PORT="${PROM_PORT:-9090}"
GEN_PORT="${GEN_PORT:-9100}"
GO="${GO:-/usr/local/go/bin/go}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="results/grow__${PROM_VERSION}__${TS}"; mkdir -p "$OUT_DIR"
AGG="$OUT_DIR/growth.csv"
PROM_LOG="$OUT_DIR/prometheus.log"; GEN_LOG="$OUT_DIR/metricgen.log"
CONFIG="$OUT_DIR/prometheus.yml"; SNAP="$OUT_DIR/.snap"
TSDB_DIR="$(mktemp -d /tmp/tsdb-grow.XXXXXX)"
PROM_URL="http://127.0.0.1:$PROM_PORT"

GEN_PIDS=()
cleanup() {
  set +e
  [[ -n "${PROM_PID:-}" ]] && kill "$PROM_PID" 2>/dev/null
  for p in "${GEN_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 1
  [[ -n "${PROM_PID:-}" ]] && kill -9 "$PROM_PID" 2>/dev/null
  for p in "${GEN_PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$TSDB_DIR"
}
trap cleanup EXIT

echo "==> grow-to-oom $PROM_VERSION  targets=$TARGETS cores=$CORES(n=$NCORES) K:$K_START+$K_STEP..$K_MAX interval=$INTERVAL"
echo "    out: $OUT_DIR"

GEN_BIN="$REPO_DIR/metricgen/metricgen"
[[ -x "$GEN_BIN" && ! metricgen/main.go -nt "$GEN_BIN" ]] || ( cd metricgen && "$GO" build -o metricgen . )

snap() { { curl -fsS "$PROM_URL/metrics" 2>/dev/null || true; } >"$SNAP"; }
sm() { awk -v m="$1" '$1==m{v=$2} END{print v}' "$SNAP"; }
sm_app() { awk '/^prometheus_tsdb_head_samples_appended_total\{type="float"\}/{v=$2} END{print v}' "$SNAP"; }
api() { curl -fsS --data-urlencode "query=$1" "$PROM_URL/api/v1/query" 2>/dev/null | jq -r '.data.result[0].value[1] // "NaN"' 2>/dev/null || echo NaN; }
prom_alive() { kill -0 "$PROM_PID" 2>/dev/null; }

# --- start TARGETS exporters at K_START -------------------------------------
echo "==> starting $TARGETS exporters at $K_START series each"
for ((k=0; k<TARGETS; k++)); do
  GOMAXPROCS=2 taskset -c "$CORES" "$GEN_BIN" -series "$K_START" -listen ":$((GEN_PORT+k))" >>"$GEN_LOG" 2>&1 &
  GEN_PIDS+=($!)
done
for ((k=0; k<TARGETS; k++)); do
  for i in $(seq 1 600); do curl -fsS "http://127.0.0.1:$((GEN_PORT+k))/healthz" >/dev/null 2>&1 && break; sleep 1; done
done

# --- config (fixed target set) + Prometheus ---------------------------------
{ echo "global:"; echo "  scrape_interval: $INTERVAL"; echo "  scrape_timeout: $INTERVAL"; echo "  evaluation_interval: 1m"
  echo "scrape_configs:"; echo "  - job_name: synthetic"; echo "    static_configs:"; echo "      - targets:"
  for ((k=0;k<TARGETS;k++)); do echo "          - \"127.0.0.1:$((GEN_PORT+k))\""; done
} > "$CONFIG"

GOMAXPROCS="$NCORES" taskset -c "$CORES" \
  "$PROM_BIN" --config.file="$CONFIG" --storage.tsdb.path="$TSDB_DIR" \
    --storage.tsdb.retention.time=6h --web.enable-lifecycle \
    --web.listen-address="127.0.0.1:$PROM_PORT" >"$PROM_LOG" 2>&1 &
PROM_PID=$!
for i in $(seq 1 60); do curl -fsS "$PROM_URL/-/ready" >/dev/null 2>&1 && break; prom_alive || { echo "prom died:"; tail "$PROM_LOG"; exit 1; }; sleep 1; done
echo "    prometheus up (pid $PROM_PID, GOMAXPROCS=$NCORES on cores $CORES)"

# Column order matches the row built below: the awk block emits
# cpu_cores,cpu_pct,cpu_s_per_million,rss_gib, then worst_scrape,min_up are appended.
echo "step,targets,series_per_target,head_series,interval_s,cpu_cores,cpu_pct_of_ncores,cpu_s_per_million,rss_gib,worst_scrape_s,min_up,event" >"$AGG"

resize_all() { # $1 = series per target
  for ((k=0;k<TARGETS;k++)); do curl -fsS "http://127.0.0.1:$((GEN_PORT+k))/resize?series=$1" >/dev/null 2>&1 || true; done
}

wait_plateau() { # sets HEAD; returns 1 on OOM
  local prev=-1 stable=0 deadline=$(( $(date +%s) + 5*INTERVAL_S + 30 ))
  while :; do
    prom_alive || return 1
    snap; HEAD="$(sm prometheus_tsdb_head_series)"; HEAD="${HEAD:-0}"
    if awk -v h="$HEAD" -v p="$prev" 'BEGIN{exit !(p>0 && h>0 && (h-p)/p<0.003)}'; then stable=$((stable+1)); else stable=0; fi
    prev="$HEAD"
    [[ "$stable" -ge 2 ]] && return 0
    [[ "$(date +%s)" -ge "$deadline" ]] && return 0
    sleep 4
  done
}

K="$K_START"; step=0
while :; do
  step=$((step+1))
  echo "== step $step: $TARGETS targets x $K = $(( TARGETS*K/1000000 ))M series intended =="
  if ! wait_plateau; then
    echo "    !! OOM/crash at step $step (~$(( TARGETS*K/1000000 ))M intended, last head=${HEAD:-NA})"
    echo "$step,$TARGETS,$K,${HEAD:-NA},$INTERVAL_S,,,,,,,OOM" >>"$AGG"; break
  fi
  # steady-state measurement over one scrape interval
  snap; c0="$(sm process_cpu_seconds_total)"; a0="$(sm_app)"; t0="$(date +%s.%N)"
  sleep "$((INTERVAL_S+3))"
  if ! prom_alive; then echo "    !! OOM during measure at step $step"; echo "$step,$TARGETS,$K,${HEAD:-NA},$INTERVAL_S,,,,,,,OOM" >>"$AGG"; break; fi
  snap; c1="$(sm process_cpu_seconds_total)"; a1="$(sm_app)"; t1="$(date +%s.%N)"
  rss="$(sm process_resident_memory_bytes)"; head="$(sm prometheus_tsdb_head_series)"
  worst="$(api 'max(scrape_duration_seconds{job="synthetic"})')"; minup="$(api 'min(up{job="synthetic"})')"
  row="$(awk -v c0="$c0" -v c1="$c1" -v a0="$a0" -v a1="$a1" -v t0="$t0" -v t1="$t1" -v r="$rss" -v nc="$NCORES" \
    'BEGIN{dt=t1-t0; dc=c1-c0; da=a1-a0; cores=(dt>0)?dc/dt:0; cpm=(da>0)?dc/(da/1e6):0;
           printf "%.3f,%.1f,%.4f,%.2f", cores, 100*cores/nc, cpm, r/1073741824}')"
  echo "$step,$TARGETS,$K,$head,$INTERVAL_S,$row,$worst,$minup," >>"$AGG"
  echo "    head=$head  cpu=$(echo "$row"|cut -d, -f1)cores ($(echo "$row"|cut -d, -f2)% of $NCORES)  cpu/Msamp=$(echo "$row"|cut -d, -f3)  worst_scrape=${worst}s  rss=$(echo "$row"|cut -d, -f4)GiB  up=$minup"

  [[ "$K" -ge "$K_MAX" ]] && { echo "reached K_MAX=$K_MAX, stopping"; break; }
  K=$((K+K_STEP)); [[ "$K" -gt "$K_MAX" ]] && K="$K_MAX"
  resize_all "$K"
done

echo; echo "==> growth complete: $AGG"
column -s, -t "$AGG" 2>/dev/null || cat "$AGG"
