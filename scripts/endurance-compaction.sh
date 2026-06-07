#!/usr/bin/env bash
# Endurance test at the 10M samples/s operating point to observe how Prometheus
# handles the first real 2h-block head compaction (and its effect on ingest).
#
# Operating point (from the core-scaling results): Prometheus on 16 cores
# (cpuset 0-15 + GOMAXPROCS=16), 32 exporters x 200k series = 6.4M head series,
# fixed scrape_interval = scrape_timeout = 0.64s -> 6.4M/0.64 = 10.0M samples/s.
# 0.64s is deliberately a hair looser than the 0.56s saturated edge so steady
# state is robust (~83% CPU) and any disruption during compaction is cleanly
# attributable to compaction rather than edge fragility.
#
# TSDB lives on a real NVMe disk (not tmpfs) so compaction does real IO and we
# have room for ~50 GB/h of blocks. Head compaction fires when the head spans
# 1.5 x 2h = 3h of sample time, i.e. ~3h of wall clock; we run ~3.5h to capture
# it plus the post-compaction settle.
#
# Samples TSDB + ingest + CPU + memory + scrape health every TICK seconds into
# endurance.csv for later analysis/plotting.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_DIR"

PROM_BIN="${PROM_BIN:?set PROM_BIN}"
PROM_VERSION="${PROM_VERSION:-v3.12.0}"
GEN_BIN="${GEN_BIN:-$REPO_DIR/metricgen/metricgen}"
TSDB_ROOT="${TSDB_ROOT:-/mnt/tsdb}"

CORES="${CORES:-16}"            # Prometheus cpuset width 0-(CORES-1) + GOMAXPROCS
TARGETS="${TARGETS:-32}"        # exporters
K="${K:-200000}"               # series per exporter -> total = TARGETS*K = 6.4M
INTERVAL="${INTERVAL:-0.64}"    # scrape_interval == scrape_timeout (s) -> 10.0 M/s
RETENTION="${RETENTION:-24h}"
DURATION_S="${DURATION_S:-12600}"   # 3.5h
TICK="${TICK:-10}"             # sampling cadence (s)
BOX="${BOX:-$(nproc)}"

GEN_PORT=19090; PROM_PORT=9090; PROM_URL="http://127.0.0.1:$PROM_PORT"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="results/endurance__${PROM_VERSION}__${TS}"; mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/endurance.csv"
CONFIG="$OUT_DIR/prometheus.yml"
PROM_LOG="$OUT_DIR/prometheus.log"; GEN_LOG="$OUT_DIR/exporters.log"
SNAP="$(mktemp)"; TSDB_DIR="$TSDB_ROOT/data-endurance"
TOTAL=$(( TARGETS * K ))

PROM_PID=""; GEN_PIDS=()
cleanup() {
  [[ -n "$PROM_PID" ]] && kill "$PROM_PID" 2>/dev/null || true
  for p in "${GEN_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  sleep 1
  [[ -n "$PROM_PID" ]] && kill -9 "$PROM_PID" 2>/dev/null || true
  for p in "${GEN_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
  rm -f "$SNAP" 2>/dev/null || true
}
trap cleanup EXIT

snap() { { curl -fsS "$PROM_URL/metrics" 2>/dev/null || true; } >"$SNAP"; }
sm()  { awk -v m="$1" '$1==m{v=$2} END{print (v==""?0:v)}' "$SNAP"; }
sm_app() { awk '/^prometheus_tsdb_head_samples_appended_total\{type="float"\}/{v=$2} END{print (v==""?0:v)}' "$SNAP"; }
# histogram _sum helper (metric name without suffix)
smsum() { awk -v m="$1_sum" '$1==m{v=$2} END{print (v==""?0:v)}' "$SNAP"; }
smcnt() { awk -v m="$1_count" '$1==m{v=$2} END{print (v==""?0:v)}' "$SNAP"; }
api() { curl -fsS --data-urlencode "query=$1" "$PROM_URL/api/v1/query" 2>/dev/null | jq -r '.data.result[0].value[1] // "NaN"' 2>/dev/null || echo NaN; }

echo "==> endurance $PROM_VERSION  10 M/s compaction test"
echo "    16 cores, $TARGETS exporters x $K = $((TOTAL/1000000))M series, interval ${INTERVAL}s"
echo "    TSDB on $TSDB_DIR (NVMe), retention $RETENTION, duration ${DURATION_S}s, tick ${TICK}s"
echo "    out: $OUT_DIR"

# fresh TSDB dir on NVMe
rm -rf "$TSDB_DIR"; mkdir -p "$TSDB_DIR"

# config: back-to-back scraping at the fixed 10M/s interval.
# Prometheus durations are integer-with-unit (no fractional seconds), so emit ms.
IMS="$(awk -v s="$INTERVAL" 'BEGIN{printf "%.0f", s*1000}')"
{ echo "global:"; echo "  scrape_interval: ${IMS}ms"; echo "  scrape_timeout: ${IMS}ms"; echo "  evaluation_interval: 1m"
  echo "scrape_configs:"; echo "  - job_name: synthetic"; echo "    static_configs:"; echo "      - targets:"
  for ((k=0;k<TARGETS;k++)); do echo "          - \"127.0.0.1:$((GEN_PORT+k))\""; done
} > "$CONFIG"

echo "  -> starting $TARGETS exporters ($K series each, float on 0-$((BOX-1)))"
for ((k=0;k<TARGETS;k++)); do
  GOMAXPROCS=1 taskset -c "0-$((BOX-1))" "$GEN_BIN" -series "$K" -listen ":$((GEN_PORT+k))" >>"$GEN_LOG" 2>&1 &
  GEN_PIDS+=($!)
done
for ((k=0;k<TARGETS;k++)); do
  for i in $(seq 1 600); do curl -fsS "http://127.0.0.1:$((GEN_PORT+k))/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
done

echo "  -> starting Prometheus on cores 0-$((CORES-1)) (GOMAXPROCS=$CORES)"
GOMAXPROCS="$CORES" taskset -c "0-$((CORES-1))" \
  "$PROM_BIN" --config.file="$CONFIG" --storage.tsdb.path="$TSDB_DIR" \
    --storage.tsdb.retention.time="$RETENTION" --web.enable-lifecycle \
    --web.listen-address="127.0.0.1:$PROM_PORT" >"$PROM_LOG" 2>&1 &
PROM_PID=$!
for i in $(seq 1 60); do curl -fsS "$PROM_URL/-/ready" >/dev/null 2>&1 && break; sleep 1; done

# wait for the head to fill to the full series set before we start the clock
echo "  -> warming to $((TOTAL/1000000))M head series..."
for i in $(seq 1 300); do
  snap; h="$(sm prometheus_tsdb_head_series)"
  awk -v h="$h" -v w="$TOTAL" 'BEGIN{exit !(h>=0.995*w)}' && break; sleep 2
done
snap; echo "     head series=$(sm prometheus_tsdb_head_series)"

echo "ts_unix,elapsed_s,head_series,head_chunks,head_min_ms,head_max_ms,head_span_s,appended_total,ingest_rate,cpu_seconds,cpu_pct16,rss_gib,scrape_max_s,min_up,compactions_total,compactions_failed,compaction_dur_sum,compaction_dur_count,head_truncations_total,head_gc_dur_sum,wal_fsync_dur_sum,wal_truncations_total,blocks_loaded,tsdb_disk_mib,mount_avail_gib" > "$CSV"

start="$(date +%s)"; prev_t=""; prev_app=""; prev_cpu=""
last_comp=0; last_trunc=0
while :; do
  now="$(date +%s)"; elapsed=$(( now - start ))
  [[ "$elapsed" -ge "$DURATION_S" ]] && break
  prom_alive() { kill -0 "$PROM_PID" 2>/dev/null; }
  prom_alive || { echo "!! prometheus exited early at ${elapsed}s"; tail -5 "$PROM_LOG"; break; }

  snap
  hs="$(sm prometheus_tsdb_head_series)"; hc="$(sm prometheus_tsdb_head_chunks)"
  hmin="$(sm prometheus_tsdb_head_min_time)"; hmax="$(sm prometheus_tsdb_head_max_time)"
  app="$(sm_app)"; cpu="$(sm process_cpu_seconds_total)"
  rss="$(sm process_resident_memory_bytes)"
  comp="$(sm prometheus_tsdb_compactions_total)"; compf="$(sm prometheus_tsdb_compactions_failed_total)"
  cdsum="$(smsum prometheus_tsdb_compaction_duration_seconds)"; cdcnt="$(smcnt prometheus_tsdb_compaction_duration_seconds)"
  htr="$(sm prometheus_tsdb_head_truncations_total)"
  hgc="$(smsum prometheus_tsdb_head_gc_duration_seconds)"
  wfs="$(smsum prometheus_tsdb_wal_fsync_duration_seconds)"
  wtr="$(sm prometheus_tsdb_wal_truncations_total)"
  bl="$(sm prometheus_tsdb_blocks_loaded)"
  minup="$(api 'min(up{job="synthetic"})')"; smax="$(api 'max(scrape_duration_seconds{job="synthetic"})')"
  disk="$(du -sm "$TSDB_DIR" 2>/dev/null | awk '{print $1}')"; disk="${disk:-0}"
  avail="$(df -BG --output=avail "$TSDB_ROOT" 2>/dev/null | awk 'NR==2{gsub("G","");print}')"; avail="${avail:-0}"

  span="$(awk -v a="$hmax" -v b="$hmin" 'BEGIN{printf "%.0f", (a-b)/1000}')"
  rss_gib="$(awk -v r="$rss" 'BEGIN{printf "%.2f", r/1073741824}')"
  rate=""; cpupct=""
  if [[ -n "$prev_t" ]]; then
    dt=$(( now - prev_t )); [[ "$dt" -le 0 ]] && dt=1
    rate="$(awk -v a="$app" -v p="$prev_app" -v dt="$dt" 'BEGIN{printf "%.0f", (a-p)/dt}')"
    cpupct="$(awk -v c="$cpu" -v p="$prev_cpu" -v dt="$dt" -v n="$CORES" 'BEGIN{printf "%.1f", 100*(c-p)/dt/n}')"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$now" "$elapsed" "$hs" "$hc" "$hmin" "$hmax" "$span" "$app" "$rate" "$cpu" "$cpupct" "$rss_gib" \
    "$smax" "$minup" "$comp" "$compf" "$cdsum" "$cdcnt" "$htr" "$hgc" "$wfs" "$wtr" "$bl" "$disk" "$avail" >> "$CSV"

  # live annotations on notable events
  if awk -v c="$comp" -v l="$last_comp" 'BEGIN{exit !(c>l)}'; then
    printf '  [%5ds] *** COMPACTION #%s done (head_trunc=%s, blocks=%s, disk=%sMiB) ***\n' "$elapsed" "$comp" "$htr" "$bl" "$disk"; last_comp="$comp"
  fi
  if awk -v t="$htr" -v l="$last_trunc" 'BEGIN{exit !(t>l)}'; then last_trunc="$htr"; fi
  # periodic heartbeat (~ every 5 min)
  if (( elapsed % 300 < TICK )); then
    printf '  [%5ds] span=%ss/%dh head=%.1fM rate=%s/s cpu=%s%% rss=%sGiB up=%s scrape=%ss disk=%sMiB\n' \
      "$elapsed" "$span" 3 "$(awk -v h="$hs" 'BEGIN{printf "%.2f", h/1e6}')" "${rate:-NA}" "${cpupct:-NA}" "$rss_gib" "$minup" "$smax" "$disk"
  fi

  prev_t="$now"; prev_app="$app"; prev_cpu="$cpu"
  sleep "$TICK"
done

echo "==> endurance run complete: $CSV"
snap
echo "    final: head=$(sm prometheus_tsdb_head_series) compactions=$(sm prometheus_tsdb_compactions_total) head_truncations=$(sm prometheus_tsdb_head_truncations_total) blocks_loaded=$(sm prometheus_tsdb_blocks_loaded)"
echo "    blocks on disk:"; ls -1 "$TSDB_DIR" 2>/dev/null | grep -vE 'wal|chunks_head|lock|^queries' || true
