#!/usr/bin/env bash
# rate-max.sh — find the PEAK sustained ingest rate (samples/s actually appended)
# of one Prometheus server on this box.
#
# Idea: ingest rate = series / scrape_period. When CPU-bound, a full scrape of C
# series across N cores takes ~ C * cpu_per_sample(C) / cores, so the sustained
# rate = cores / cpu_per_sample(C). cpu_per_sample is cheapest at low/moderate
# cardinality, so peak rate lives there — NOT at the OOM ceiling. To measure the
# true peak at each cardinality we must run scrapes BACK TO BACK (no idle, no
# timeout): so for each cardinality we (1) warm it at a generous probe interval,
# (2) read the steady scrape duration D, (3) set scrape_interval == scrape_timeout
# just above D and reload, (4) measure the appended-samples rate over a window.
#
# We use TARGETS > cores so every core always has a warm scrape ready to run.
#
# Measured per step (ONLY what we care about here):
#   ingest_rate_per_s = d(head_samples_appended_total{float}) / dt   (truly ingested)
#   cpu_pct_of_ncores , cpu_cores                                    (ingest CPU)
#   rss_gib                                                          (memory used)
#   scrape_s is recorded only to size the interval; plotting skips it.
#
# Usage:
#   PROM_BIN=/home/jbran/prometheus-3.12.0.linux-amd64/prometheus PROM_VERSION=v3.12.0 \
#     bash scripts/rate-max.sh
#
# Env:
#   TARGETS     exporters/targets (> cores)                 (default 24)
#   CORES       cpu set prom+exporters share                (default 0-15)
#   K_LIST      per-target series values to sweep           (default below)
#   HEADROOM    interval = scrape_duration * HEADROOM       (default 1.2)
#   INT_FLOOR_MS minimum scrape interval in ms              (default 250)
#   PROBE_INTERVAL generous interval used while creating    (default 30s)
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_DIR"

: "${PROM_BIN:?set PROM_BIN}"; : "${PROM_VERSION:?set PROM_VERSION}"
TARGETS="${TARGETS:-24}"
CORES="${CORES:-0-15}"
NCORES=$(( $(echo "$CORES" | awk -F- '{print ($2?$2:$1)-$1+1}') ))
# per-target series; totals (x24) = 2.4,4.8,9.6,14.4,19.2,28.8,38.4 M
K_LIST="${K_LIST:-100000 200000 400000 600000 800000 1200000 1600000}"
HEADROOM="${HEADROOM:-1.2}"
INT_FLOOR_MS="${INT_FLOOR_MS:-250}"
PROBE_INTERVAL="${PROBE_INTERVAL:-30s}"; PROBE_S="${PROBE_INTERVAL%s}"
PROM_PORT="${PROM_PORT:-9090}"; GEN_PORT="${GEN_PORT:-9100}"
GO="${GO:-/usr/local/go/bin/go}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="results/ratemax__${PROM_VERSION}__${TS}"; mkdir -p "$OUT_DIR"
AGG="$OUT_DIR/ratemax.csv"
PROM_LOG="$OUT_DIR/prometheus.log"; GEN_LOG="$OUT_DIR/metricgen.log"
CONFIG="$OUT_DIR/prometheus.yml"; SNAP="$OUT_DIR/.snap"
TSDB_DIR="$(mktemp -d /tmp/tsdb-rate.XXXXXX)"
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

read -r -a KS <<<"$K_LIST"; K_START="${KS[0]}"
echo "==> rate-max $PROM_VERSION  targets=$TARGETS cores=$CORES(n=$NCORES)  K_LIST=[$K_LIST]"
echo "    box: $NCORES vCPU / $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo) GiB RAM"
echo "    out: $OUT_DIR"

GEN_BIN="$REPO_DIR/metricgen/metricgen"
[[ -x "$GEN_BIN" && ! metricgen/main.go -nt "$GEN_BIN" ]] || ( cd metricgen && "$GO" build -o metricgen . )

snap() { { curl -fsS "$PROM_URL/metrics" 2>/dev/null || true; } >"$SNAP"; }
sm() { awk -v m="$1" '$1==m{v=$2} END{print v}' "$SNAP"; }
sm_app() { awk '/^prometheus_tsdb_head_samples_appended_total\{type="float"\}/{v=$2} END{print v}' "$SNAP"; }
api() { curl -fsS --data-urlencode "query=$1" "$PROM_URL/api/v1/query" 2>/dev/null | jq -r '.data.result[0].value[1] // "NaN"' 2>/dev/null || echo NaN; }
prom_alive() { kill -0 "$PROM_PID" 2>/dev/null; }

write_config() { # $1 = interval string (e.g. 30s, 1700ms)
  { echo "global:"; echo "  scrape_interval: $1"; echo "  scrape_timeout: $1"; echo "  evaluation_interval: 1m"
    echo "scrape_configs:"; echo "  - job_name: synthetic"; echo "    static_configs:"; echo "      - targets:"
    for ((k=0;k<TARGETS;k++)); do echo "          - \"127.0.0.1:$((GEN_PORT+k))\""; done
  } > "$CONFIG"
}
reload() { curl -fsS -X POST "$PROM_URL/-/reload" >/dev/null 2>&1; }

# --- start TARGETS exporters at K_START -------------------------------------
echo "==> starting $TARGETS exporters at $K_START series each"
for ((k=0; k<TARGETS; k++)); do
  GOMAXPROCS=2 taskset -c "$CORES" "$GEN_BIN" -series "$K_START" -listen ":$((GEN_PORT+k))" >>"$GEN_LOG" 2>&1 &
  GEN_PIDS+=($!)
done
for ((k=0; k<TARGETS; k++)); do
  for i in $(seq 1 600); do curl -fsS "http://127.0.0.1:$((GEN_PORT+k))/healthz" >/dev/null 2>&1 && break; sleep 1; done
done

write_config "$PROBE_INTERVAL"
GOMAXPROCS="$NCORES" taskset -c "$CORES" \
  "$PROM_BIN" --config.file="$CONFIG" --storage.tsdb.path="$TSDB_DIR" \
    --storage.tsdb.retention.time=6h --web.enable-lifecycle \
    --web.listen-address="127.0.0.1:$PROM_PORT" >"$PROM_LOG" 2>&1 &
PROM_PID=$!
for i in $(seq 1 60); do curl -fsS "$PROM_URL/-/ready" >/dev/null 2>&1 && break; prom_alive || { echo "prom died:"; tail "$PROM_LOG"; exit 1; }; sleep 1; done
echo "    prometheus up (pid $PROM_PID, GOMAXPROCS=$NCORES on cores $CORES)"

echo "step,targets,series_per_target,head_series,interval_s,scrape_s,ingest_rate_per_s,cpu_cores,cpu_pct_of_ncores,rss_gib,min_up,event" >"$AGG"

resize_all() { for ((k=0;k<TARGETS;k++)); do curl -fsS "http://127.0.0.1:$((GEN_PORT+k))/resize?series=$1" >/dev/null 2>&1 || true; done; }

wait_plateau() { # warm at probe interval until head stops growing; sets HEAD; 1 on OOM
  local prev=-1 stable=0 deadline=$(( $(date +%s) + 600 ))
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

measure() { # over window WIN seconds: sets RATE CORES PCT CPM RSS HEAD MINUP; 1 on OOM
  local win="$1"
  snap; local c0 a0 t0; c0="$(sm process_cpu_seconds_total)"; a0="$(sm_app)"; t0="$(date +%s.%N)"
  sleep "$win"
  prom_alive || return 1
  snap; local c1 a1 t1; c1="$(sm process_cpu_seconds_total)"; a1="$(sm_app)"; t1="$(date +%s.%N)"
  RSS="$(sm process_resident_memory_bytes)"; HEAD="$(sm prometheus_tsdb_head_series)"
  MINUP="$(api 'min(up{job="synthetic"})')"
  read -r RATE CORES PCT < <(awk -v c0="$c0" -v c1="$c1" -v a0="$a0" -v a1="$a1" -v t0="$t0" -v t1="$t1" -v nc="$NCORES" \
    'BEGIN{dt=t1-t0; printf "%.0f %.3f %.1f", (a1-a0)/dt, (c1-c0)/dt, 100*(c1-c0)/dt/nc}')
  RSS_GIB="$(awk -v r="$RSS" 'BEGIN{printf "%.2f", r/1073741824}')"
  return 0
}

set_interval() { # $1 = seconds (float) -> writes config in ms and reloads
  CUR_S="$1"; CUR_MS="$(awk -v s="$1" 'BEGIN{printf "%.0f", s*1000}')"
  write_config "${CUR_MS}ms"; reload
}

OOM=0
step=0
for K in "${KS[@]}"; do
  step=$((step+1)); TOT=$(( TARGETS*K ))
  echo "== step $step: $TARGETS x $K = $((TOT/1000000)).$(((TOT/100000)%10))M series =="
  if [[ "$step" -gt 1 ]]; then resize_all "$K"; fi
  # warm at the generous probe interval so the (slow) creation scrapes never time out
  write_config "$PROBE_INTERVAL"; reload; sleep 2
  if ! wait_plateau; then echo "  !! OOM while warming (~${TOT} series)"; echo "$step,$TARGETS,$K,${HEAD:-NA},,,,,,,,OOM" >>"$AGG"; OOM=1; break; fi
  echo "  warmed: head=$HEAD"

  # Closed loop: tighten the scrape interval toward the back-to-back (CPU-bound)
  # regime. We can't trust the post-creation scrape time, so we probe: measure,
  # then if CPU is not saturated tighten to ~the observed steady scrape duration;
  # if scrapes start timing out (min_up<1) back off. Keep the best min_up==1 row.
  CUR_S="$PROBE_S"; best_rate=-1; best_row=""; best_line=""
  for iter in $(seq 1 6); do
    WIN="$(awk -v s="$CUR_S" 'BEGIN{w=8*s; if(w<10)w=10; if(w>25)w=25; printf "%.0f", w}')"
    sleep "$(awk -v s="$CUR_S" 'BEGIN{w=3*s; if(w<3)w=3; if(w>20)w=20; printf "%.0f", w}')"
    if ! measure "$WIN"; then echo "  !! OOM during measure"; echo "$step,$TARGETS,$K,${HEAD:-NA},$CUR_S,,,,,,,OOM" >>"$AGG"; OOM=1; break; fi
    D="$(api 'max(scrape_duration_seconds{job="synthetic"})')"
    printf "    iter%s int=%.2fs win=%ss -> rate=%'d/s  cpu=%s%%  scrape=%.2fs  up=%s\n" \
      "$iter" "$CUR_S" "$WIN" "$RATE" "$PCT" "$D" "$MINUP"
    upok="$(awk -v u="$MINUP" 'BEGIN{print (u>=0.999)?1:0}')"
    if [[ "$upok" == 1 ]] && awk -v r="$RATE" -v b="$best_rate" 'BEGIN{exit !(r>b)}'; then
      best_rate="$RATE"; best_line="$step,$TARGETS,$K,$HEAD,$CUR_S,$D,$RATE,$CORES,$PCT,$RSS_GIB,$MINUP,"
      best_row="head=$HEAD rate=$RATE cpu=${PCT}% rss=${RSS_GIB}GiB int=${CUR_S}s"
    fi
    if [[ "$upok" != 1 ]]; then               # timed out -> loosen and stop tightening
      CUR_S="$(awk -v s="$CUR_S" 'BEGIN{printf "%.3f", s*1.5}')"; set_interval "$CUR_S"; continue
    fi
    if awk -v p="$PCT" 'BEGIN{exit !(p>=85)}'; then break; fi   # CPU saturated -> peak found
    # not saturated: tighten toward the observed scrape duration (with headroom)
    NEXT="$(awk -v d="$D" -v h="$HEADROOM" -v fl="$INT_FLOOR_MS" 'BEGIN{n=d*h; if(n<fl/1000)n=fl/1000; printf "%.3f", n}')"
    if awk -v n="$NEXT" -v c="$CUR_S" 'BEGIN{exit !(n>=c*0.92)}'; then break; fi  # can't tighten further
    CUR_S="$NEXT"; set_interval "$CUR_S"
  done
  [[ "$OOM" == 1 ]] && break
  if [[ -n "$best_line" ]]; then
    echo "$best_line" >>"$AGG"
    printf "  => best: %s\n" "$best_row"
  fi
done

echo; echo "==> rate sweep complete: $AGG"
column -s, -t "$AGG" 2>/dev/null || cat "$AGG"
echo
echo "peak ingest rate:"
awk -F, 'NR>1 && $7!="" {if($7+0>m){m=$7;l=$0}} END{if(l!=""){split(l,a,","); printf "  %.2f M samples/s at %.1fM head series (%s%% CPU, %s GiB)\n", m/1e6, a[4]/1e6, a[9], a[10]}}' "$AGG"
