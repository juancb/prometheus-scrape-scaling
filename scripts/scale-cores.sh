#!/usr/bin/env bash
# scale-cores.sh — how does Prometheus single-server ingest throughput scale with
# CPU cores, and how many cores does it take to sustain 10M samples/s?
#
# Design (a controlled experiment, not just a sweep):
#   - Independent variable: cores given to Prometheus, N (cpuset 0..N-1, GOMAXPROCS=N).
#   - Held CONSTANT: per-core cardinality. We set TARGETS = TPC * N exporters, each
#     serving K series, so total head series = TPC*K*N and series-per-core = TPC*K is
#     identical at every N. That isolates "more cores" from "more series": per-sample
#     append cost stays fixed, so any departure from linear rate-vs-cores is a shared
#     resource limit (memory bandwidth, GC, allocator, cross-core cache traffic), not a
#     change in workload.
#   - Exporters float across the WHOLE box (taskset 0-(BOX-1), GOMAXPROCS=1). They serve
#     a precomputed payload (~0 CPU) so the scheduler parks them on idle cores and they
#     don't steal from Prometheus' cpuset. Verified: ingest CPU still reaches >90% of N.
#   - Dependent variable: PEAK sustained ingest rate = d(head_samples_appended_total)/dt,
#     measured back-to-back (scrape_interval == scrape_timeout, self-calibrated just above
#     the steady scrape duration so no scrape times out and drops its samples).
#   - REPLICATES cold restarts per N -> mean +/- CI downstream. Each replicate is a fresh
#     Prometheus on a fresh tmpfs TSDB; exporters stay up within an N (cardinality fixed).
#
# Output: results/scale-cores__<ts>/scale.csv  (one row PER REPLICATE)
#   cores,targets,total_series,replicate,interval_s,scrape_s,ingest_rate_per_s,
#   cpu_cores,cpu_pct_of_ncores,rss_gib,min_up,event
#
# Usage:
#   PROM_BIN=/home/ubuntu/prometheus-3.12.0.linux-amd64/prometheus PROM_VERSION=v3.12.0 \
#     bash scripts/scale-cores.sh
#
# Env (defaults tuned for a 64 vCPU / 124 GiB box, all data fits RAM, no OOM):
#   CORE_LIST   Prometheus core counts to sweep     (default "4 8 16 24 32 40 48 56 64")
#   REPLICATES  cold restarts per core count        (default 5)
#   K           series per target                   (default 200000)
#   TPC         targets per core (TARGETS = TPC*N)   (default 2)
#   MEAS_WIN    measurement window seconds          (default 18)
#   CPU_TARGET  CPU% we drive the scrape interval to (default 92)
#   INT_FLOOR_MS minimum scrape interval ms         (default 150)
#   MAX_ITERS   interval-controller iterations      (default 7)
#   PROBE_INTERVAL warm-up interval                 (default 30s)
#   BOX         total vCPUs on the box              (default: nproc)
#
# Why K=200k, TPC=2: each scrape then takes ~0.2s, and to keep N cores busy the
# saturating interval is ~TPC*scrape ~= 0.4s -- comfortably above the 150ms floor, so
# the CPU-bound regime is REACHABLE at every core count (a smaller K leaves the cores
# idle between sub-floor scrapes and you measure an interval-limited rate, not the
# peak). Per-core cardinality = TPC*K = 400k; total at 64 cores = 25.6M series
# (~48 GiB RSS) -- safely under this box's ~76M-series tmpfs-OOM ceiling.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_DIR"

: "${PROM_BIN:?set PROM_BIN}"; : "${PROM_VERSION:?set PROM_VERSION}"
CORE_LIST="${CORE_LIST:-4 8 16 24 32 40 48 56 64}"
REPLICATES="${REPLICATES:-5}"
K="${K:-200000}"
TPC="${TPC:-2}"
MEAS_WIN="${MEAS_WIN:-18}"
CPU_TARGET="${CPU_TARGET:-92}"
INT_FLOOR_MS="${INT_FLOOR_MS:-150}"
MAX_ITERS="${MAX_ITERS:-7}"
PROBE_INTERVAL="${PROBE_INTERVAL:-12s}"; PROBE_S="${PROBE_INTERVAL%s}"
BOX="${BOX:-$(nproc)}"
PROM_PORT="${PROM_PORT:-9090}"; GEN_PORT="${GEN_PORT:-9100}"
GO="${GO:-/usr/local/go/bin/go}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="results/scale-cores__${PROM_VERSION}__${TS}"; mkdir -p "$OUT_DIR"
AGG="$OUT_DIR/scale.csv"
PROM_LOG="$OUT_DIR/prometheus.log"; GEN_LOG="$OUT_DIR/metricgen.log"
CONFIG="$OUT_DIR/prometheus.yml"; SNAP="$OUT_DIR/.snap"
PROM_URL="http://127.0.0.1:$PROM_PORT"

GEN_PIDS=(); PROM_PID=""; TSDB_DIR=""
cleanup() {
  set +e
  [[ -n "$PROM_PID" ]] && kill "$PROM_PID" 2>/dev/null
  for p in "${GEN_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 1
  [[ -n "$PROM_PID" ]] && kill -9 "$PROM_PID" 2>/dev/null
  for p in "${GEN_PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  [[ -n "$TSDB_DIR" ]] && rm -rf "$TSDB_DIR"
}
trap cleanup EXIT

GEN_BIN="$REPO_DIR/metricgen/metricgen"
[[ -x "$GEN_BIN" && ! metricgen/main.go -nt "$GEN_BIN" ]] || ( cd metricgen && "$GO" build -o metricgen . )

echo "==> scale-cores $PROM_VERSION  box=${BOX}vCPU  CORE_LIST=[$CORE_LIST]  reps=$REPLICATES"
echo "    per-core cardinality held at TPC*K = $((TPC*K)) series/core (TARGETS=${TPC}N, K=$K)"
echo "    box: ${BOX} vCPU / $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo) GiB RAM"
echo "    out: $OUT_DIR"

snap() { { curl -fsS "$PROM_URL/metrics" 2>/dev/null || true; } >"$SNAP"; }
sm() { awk -v m="$1" '$1==m{v=$2} END{print v}' "$SNAP"; }
sm_app() { awk '/^prometheus_tsdb_head_samples_appended_total\{type="float"\}/{v=$2} END{print v}' "$SNAP"; }
api() { curl -fsS --data-urlencode "query=$1" "$PROM_URL/api/v1/query" 2>/dev/null | jq -r '.data.result[0].value[1] // "NaN"' 2>/dev/null || echo NaN; }
prom_alive() { [[ -n "$PROM_PID" ]] && kill -0 "$PROM_PID" 2>/dev/null; }
port_free() { ! ss -ltn 2>/dev/null | grep -q ":$PROM_PORT "; }
wait_port_free() { for i in $(seq 1 60); do port_free && return 0; sleep 0.5; done; return 1; }

write_config() { # $1 = interval string, $2 = #targets
  { echo "global:"; echo "  scrape_interval: $1"; echo "  scrape_timeout: $1"; echo "  evaluation_interval: 1m"
    echo "scrape_configs:"; echo "  - job_name: synthetic"; echo "    static_configs:"; echo "      - targets:"
    for ((k=0;k<$2;k++)); do echo "          - \"127.0.0.1:$((GEN_PORT+k))\""; done
  } > "$CONFIG"
}
reload() { curl -fsS -X POST "$PROM_URL/-/reload" >/dev/null 2>&1 || true; }

start_exporters() { # $1 = #targets
  local n="$1"
  echo "  -> starting $n exporters at $K series each (float on cores 0-$((BOX-1)))"
  GEN_PIDS=()
  for ((k=0;k<n;k++)); do
    GOMAXPROCS=1 taskset -c "0-$((BOX-1))" "$GEN_BIN" -series "$K" -listen ":$((GEN_PORT+k))" >>"$GEN_LOG" 2>&1 &
    GEN_PIDS+=($!)
  done
  for ((k=0;k<n;k++)); do
    for i in $(seq 1 600); do curl -fsS "http://127.0.0.1:$((GEN_PORT+k))/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
  done
}
stop_exporters() {
  for p in "${GEN_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in "${GEN_PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
  GEN_PIDS=()
}

start_prom() { # $1 = N cores, $2 = #targets, $3 = interval string
  local n="$1" tg="$2" iv="$3"
  TSDB_DIR="$(mktemp -d /tmp/tsdb-scale.XXXXXX)"
  write_config "$iv" "$tg"
  GOMAXPROCS="$n" taskset -c "0-$((n-1))" \
    "$PROM_BIN" --config.file="$CONFIG" --storage.tsdb.path="$TSDB_DIR" \
      --storage.tsdb.retention.time=6h --web.enable-lifecycle \
      --web.listen-address="127.0.0.1:$PROM_PORT" >"$PROM_LOG" 2>&1 &
  PROM_PID=$!
  for i in $(seq 1 60); do curl -fsS "$PROM_URL/-/ready" >/dev/null 2>&1 && return 0; prom_alive || { echo "  !! prom died:"; tail -3 "$PROM_LOG"; return 1; }; sleep 1; done
  return 1
}
stop_prom() {
  # NB: never let teardown trip `set -e`. Prometheus exits gracefully on SIGTERM,
  # often before the kill -9 fires, so kill -9 returns non-zero (process gone) --
  # and wait_port_free can return 1 on a slow socket release. Both are benign here.
  [[ -n "$PROM_PID" ]] && kill "$PROM_PID" 2>/dev/null || true
  sleep 1
  [[ -n "$PROM_PID" ]] && kill -9 "$PROM_PID" 2>/dev/null || true
  PROM_PID=""
  [[ -n "$TSDB_DIR" ]] && rm -rf "$TSDB_DIR" 2>/dev/null || true; TSDB_DIR=""
  wait_port_free || true
  return 0
}

wait_plateau() { # $1 = expected total series; warm until head reaches it; sets HEAD
  local want="$1" deadline=$(( $(date +%s) + 300 ))
  while :; do
    prom_alive || return 1
    snap; HEAD="$(sm prometheus_tsdb_head_series)"; HEAD="${HEAD:-0}"
    awk -v h="$HEAD" -v w="$want" 'BEGIN{exit !(h>=0.995*w)}' && return 0
    [[ "$(date +%s)" -ge "$deadline" ]] && return 0
    sleep 2
  done
}

measure() { # over $1 s: sets RATE CPUCORES PCT RSS_GIB HEAD MINUP SCRAPE
  local win="$1"
  snap; local c0 a0 t0; c0="$(sm process_cpu_seconds_total)"; a0="$(sm_app)"; t0="$(date +%s.%N)"
  sleep "$win"
  prom_alive || return 1
  snap; local c1 a1 t1; c1="$(sm process_cpu_seconds_total)"; a1="$(sm_app)"; t1="$(date +%s.%N)"
  RSS="$(sm process_resident_memory_bytes)"; HEAD="$(sm prometheus_tsdb_head_series)"
  MINUP="$(api 'min(up{job="synthetic"})')"
  SCRAPE="$(api 'max(scrape_duration_seconds{job="synthetic"})')"
  read -r RATE CPUCORES PCT < <(awk -v c0="$c0" -v c1="$c1" -v a0="$a0" -v a1="$a1" -v t0="$t0" -v t1="$t1" -v nc="$2" \
    'BEGIN{dt=t1-t0; printf "%.0f %.3f %.1f", (a1-a0)/dt, (c1-c0)/dt, 100*(c1-c0)/dt/nc}')
  RSS_GIB="$(awk -v r="$RSS" 'BEGIN{printf "%.2f", r/1073741824}')"
  return 0
}

echo "cores,targets,total_series,replicate,interval_s,scrape_s,ingest_rate_per_s,cpu_cores,cpu_pct_of_ncores,rss_gib,min_up,event" >"$AGG"

read -r -a NS <<<"$CORE_LIST"
for N in "${NS[@]}"; do
  TARGETS=$(( TPC * N )); TOTAL=$(( TARGETS * K ))
  echo "== cores=$N  targets=$TARGETS  total=$((TOTAL/1000000)).$(((TOTAL/100000)%10))M series  ($((TPC*K)) series/core) =="
  start_exporters "$TARGETS"

  for r in $(seq 1 "$REPLICATES"); do
    # cold Prometheus, warm at probe interval so creation scrapes never time out
    if ! start_prom "$N" "$TARGETS" "$PROBE_INTERVAL"; then echo "  rep$r: prom failed to start"; echo "$N,$TARGETS,$TOTAL,$r,,,,,,,,PROM_START_FAIL" >>"$AGG"; stop_prom; continue; fi
    if ! wait_plateau "$TOTAL"; then echo "  rep$r: died while warming"; echo "$N,$TARGETS,$TOTAL,$r,,,,,,,,OOM_WARM" >>"$AGG"; stop_prom; continue; fi

    # Seed the interval from the steady single-scrape duration, then run a closed-loop
    # controller on CPU%: too-loose (CPU<target, no timeouts) -> tighten proportionally;
    # too-tight (scrapes time out, min_up<1) -> loosen. The peak sustained rate is the
    # best d(appended)/dt observed with min_up==1 (every target scraped in time). We
    # keep that best row rather than the final iter, since pushing to 100% CPU can
    # thrash caches and REDUCE throughput.
    D="$(api 'max(scrape_duration_seconds{job="synthetic"})')"
    IVAL="$(awk -v d="$D" -v t="$TPC" -v fl="$INT_FLOOR_MS" 'BEGIN{n=d*t; if(n<fl/1000)n=fl/1000; printf "%.3f", n}')"
    set_interval() { IMS="$(awk -v s="$1" 'BEGIN{printf "%.0f", s*1000}')"; write_config "${IMS}ms" "$TARGETS"; reload; }
    best_rate=-1; best_line=""; best_desc=""; died=0
    for iter in $(seq 1 "$MAX_ITERS"); do
      set_interval "$IVAL"
      sleep "$(awk -v s="$IVAL" 'BEGIN{w=3*s; if(w<3)w=3; if(w>12)w=12; printf "%.0f", w}')"
      if ! measure "$MEAS_WIN" "$N"; then echo "  rep$r: died during measure"; echo "$N,$TARGETS,$TOTAL,$r,$IVAL,,,,,,,OOM_MEAS" >>"$AGG"; died=1; break; fi
      upok="$(awk -v u="$MINUP" 'BEGIN{print (u>=0.999)?1:0}')"
      printf "    rep%s.i%s int=%.0fms cpu=%.0f%% rate=%'d/s up=%s scrape=%.2fs\n" "$r" "$iter" "$IMS" "$PCT" "$RATE" "$MINUP" "$SCRAPE"
      if [[ "$upok" == 1 ]] && awk -v r="$RATE" -v b="$best_rate" 'BEGIN{exit !(r>b)}'; then
        best_rate="$RATE"; best_line="$N,$TARGETS,$TOTAL,$r,$IVAL,$SCRAPE,$RATE,$CPUCORES,$PCT,$RSS_GIB,$MINUP,"
        best_desc="$(printf "rate=%'d/s cpu=%.0f%% rss=%.1fGiB int=%.0fms" "$RATE" "$PCT" "$RSS_GIB" "$IMS")"
      fi
      if [[ "$upok" != 1 ]]; then                                   # timed out -> loosen
        IVAL="$(awk -v s="$IVAL" 'BEGIN{printf "%.3f", s*1.35}')"; continue; fi
      if awk -v p="$PCT" -v t="$CPU_TARGET" 'BEGIN{exit !(p>=t)}'; then break; fi   # saturated
      # not saturated, no timeouts -> tighten proportionally toward CPU_TARGET
      NEXT="$(awk -v s="$IVAL" -v p="$PCT" -v t="$CPU_TARGET" -v fl="$INT_FLOOR_MS" \
        'BEGIN{f=p/t; if(f<0.45)f=0.45; if(f>0.92)f=0.92; n=s*f; if(n<fl/1000)n=fl/1000; printf "%.3f", n}')"
      if awk -v n="$NEXT" -v c="$IVAL" 'BEGIN{exit !(n>=c*0.94)}'; then break; fi   # can't tighten (floor)
      IVAL="$NEXT"
    done
    [[ "$died" == 1 ]] && { stop_prom; continue; }
    if [[ -n "$best_line" ]]; then echo "$best_line" >>"$AGG"; printf "  rep%s => %s\n" "$r" "$best_desc"; fi
    stop_prom
  done
  stop_exporters
done

echo; echo "==> scale sweep complete: $AGG"
column -s, -t "$AGG" 2>/dev/null || cat "$AGG"
