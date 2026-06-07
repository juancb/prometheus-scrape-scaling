#!/usr/bin/env bash
# run-bench.sh — one Prometheus ingest benchmark run.
#
# Starts a synthetic exporter (metricgen) and one Prometheus instance, pins each
# to a disjoint set of CPU cores, scrapes Prometheus' own metrics + query API
# once per second, and writes a per-run CSV plus a summary.json / summary.txt.
#
# The whole point is to isolate INGEST CPU: the generator serves a precomputed
# payload (near-zero CPU) on cores GEN_CORES, Prometheus ingests on PROM_CORES,
# and we read Prometheus' authoritative process_cpu_seconds_total.
#
# Usage:
#   PROM_BIN=/usr/bin/prometheus PROM_VERSION=apt-2.45.3 \
#   SERIES=100000 DURATION=30 bash scripts/run-bench.sh
#
# Key env knobs (all optional except the few above):
#   PROM_BIN        path to prometheus binary            (required)
#   PROM_VERSION    label for this binary, e.g. v3.12.0  (required)
#   SERIES          unique series to expose/ingest       (default 100000)
#   DURATION        sample window in seconds             (default 30)
#   INTERVAL        scrape interval                      (default 1s)
#   TIMEOUT         scrape timeout                       (default = INTERVAL)
#   PROM_CORES      cpu set for prometheus               (default 0-7)
#   GEN_CORES       cpu set for generator                (default 8-15)
#   PROM_PORT       (default 9090)   GEN_PORT (default 9100)
#   EXTRA_LABELS    extra constant labels per series     (default 0)
#   WARMUP          samples to discard before delta calc (default 5)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

: "${PROM_BIN:?set PROM_BIN to a prometheus binary}"
: "${PROM_VERSION:?set PROM_VERSION label, e.g. apt-2.45.3 or v3.12.0}"
SERIES="${SERIES:-100000}"
DURATION="${DURATION:-30}"
INTERVAL="${INTERVAL:-1s}"
TIMEOUT="${TIMEOUT:-$INTERVAL}"
PROM_CORES="${PROM_CORES:-0-7}"
GEN_CORES="${GEN_CORES:-8-15}"
PROM_PORT="${PROM_PORT:-9090}"
GEN_PORT="${GEN_PORT:-9100}"
EXTRA_LABELS="${EXTRA_LABELS:-0}"
WARMUP="${WARMUP:-5}"
GO="${GO:-/usr/local/go/bin/go}"

# AUTO_INTERVAL=1 sizes scrape interval=timeout to the expected one-time series
# CREATION time (creation runs ~CREATE_RATE series/s on this host), so the big
# first scrape can complete instead of hitting the timeout wall. After the head
# fills, recurring scrapes are fast re-appends and we measure steady-state there.
AUTO_INTERVAL="${AUTO_INTERVAL:-0}"
CREATE_RATE="${CREATE_RATE:-150000}"   # series/s, measured on this box (~167k, derated)
SAFETY="${SAFETY:-1.6}"                 # interval headroom over estimated creation time
MIN_T="${MIN_T:-5}"; MAX_T="${MAX_T:-1200}"
STEADY_TAIL="${STEADY_TAIL:-90}"        # extra seconds after creation to watch steady-state
if [[ "$AUTO_INTERVAL" == 1 ]]; then
  T="$(awk -v s="$SERIES" -v r="$CREATE_RATE" -v k="$SAFETY" -v lo="$MIN_T" -v hi="$MAX_T" \
        'BEGIN{t=int(s/r*k)+1; if(t<lo)t=lo; if(t>hi)t=hi; print t}')"
  INTERVAL="${T}s"; TIMEOUT="${T}s"
  DURATION="${DURATION_OVERRIDE:-$((T + STEADY_TAIL))}"
  echo "    AUTO_INTERVAL: interval=timeout=${T}s, duration=${DURATION}s (create_rate=${CREATE_RATE}/s)"
fi

# Count CPUs in a set like "0-7" or "0,2,4" so we can pin GOMAXPROCS to match.
count_cores() {
  local spec="$1" total=0 part a b
  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      a="${part%-*}"; b="${part#*-}"; total=$((total + b - a + 1))
    else
      total=$((total + 1))
    fi
  done
  echo "$total"
}
PROM_NCORES="$(count_cores "$PROM_CORES")"
GEN_NCORES="$(count_cores "$GEN_CORES")"

TS="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${PROM_VERSION}__series-${SERIES}__${TS}"
OUT_DIR="results/${RUN_ID}"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/samples.csv"
GEN_LOG="$OUT_DIR/metricgen.log"
PROM_LOG="$OUT_DIR/prometheus.log"
TSDB_DIR="$(mktemp -d /tmp/tsdb-bench.XXXXXX)"

cleanup() {
  set +e
  [[ -n "${PROM_PID:-}" ]] && kill "$PROM_PID" 2>/dev/null
  [[ -n "${GEN_PID:-}" ]] && kill "$GEN_PID" 2>/dev/null
  sleep 1
  [[ -n "${PROM_PID:-}" ]] && kill -9 "$PROM_PID" 2>/dev/null
  [[ -n "${GEN_PID:-}" ]] && kill -9 "$GEN_PID" 2>/dev/null
  rm -rf "$TSDB_DIR"
}
trap cleanup EXIT

echo "==> Run $RUN_ID"
echo "    prom=$PROM_BIN cores=$PROM_CORES (n=$PROM_NCORES)  gen cores=$GEN_CORES (n=$GEN_NCORES)"
echo "    series=$SERIES duration=${DURATION}s interval=$INTERVAL timeout=$TIMEOUT"

# --- build generator (once) -------------------------------------------------
GEN_BIN="$REPO_DIR/metricgen/metricgen"
if [[ ! -x "$GEN_BIN" || metricgen/main.go -nt "$GEN_BIN" ]]; then
  echo "==> building metricgen"
  ( cd metricgen && "$GO" build -o metricgen . )
fi

# --- render prometheus config ----------------------------------------------
CONFIG="$OUT_DIR/prometheus.yml"
sed -e "s/__INTERVAL__/$INTERVAL/" \
    -e "s/__TIMEOUT__/$TIMEOUT/" \
    -e "s/__GEN_PORT__/$GEN_PORT/" \
    configs/prometheus.tmpl.yml > "$CONFIG"

# --- start generator --------------------------------------------------------
echo "==> starting metricgen (building $SERIES-series payload)"
GOMAXPROCS="$GEN_NCORES" taskset -c "$GEN_CORES" \
  "$GEN_BIN" -series "$SERIES" -listen ":$GEN_PORT" -extra-labels "$EXTRA_LABELS" \
  >"$GEN_LOG" 2>&1 &
GEN_PID=$!

# Wait for the payload to be built and the endpoint to answer.
for i in $(seq 1 600); do
  if curl -fsS "http://127.0.0.1:$GEN_PORT/healthz" >/dev/null 2>&1; then break; fi
  kill -0 "$GEN_PID" 2>/dev/null || { echo "metricgen died during build:"; cat "$GEN_LOG"; exit 1; }
  sleep 1
done
GEN_BYTES="$(curl -fsS "http://127.0.0.1:$GEN_PORT/healthz" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')"
echo "    metricgen ready: payload ${GEN_BYTES:-?} bytes"

# --- start prometheus -------------------------------------------------------
echo "==> starting prometheus ($PROM_VERSION)"
GOMAXPROCS="$PROM_NCORES" taskset -c "$PROM_CORES" \
  "$PROM_BIN" \
    --config.file="$CONFIG" \
    --storage.tsdb.path="$TSDB_DIR" \
    --storage.tsdb.retention.time=6h \
    --web.listen-address="127.0.0.1:$PROM_PORT" \
    >"$PROM_LOG" 2>&1 &
PROM_PID=$!

for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1; then break; fi
  kill -0 "$PROM_PID" 2>/dev/null || { echo "prometheus died at startup:"; tail -20 "$PROM_LOG"; exit 1; }
  sleep 1
done
echo "    prometheus ready (pid $PROM_PID)"

# --- helpers to read metrics ------------------------------------------------
PROM_URL="http://127.0.0.1:$PROM_PORT"
# pull a single gauge/counter value out of prometheus' own /metrics text
self_metric() { # $1 = metric name (exact, no labels)
  # Read the whole stream (no early awk exit) so curl never hits SIGPIPE/write-error
  # which, under `pipefail`, would abort the run.
  { curl -fsS "$PROM_URL/metrics" 2>/dev/null || true; } \
    | awk -v m="$1" '$1==m{v=$2} END{print v}'
}
# instant-query the synthetic target's scrape health via the API
api_scalar() { # $1 = promql returning a single series for job synthetic
  curl -fsS --data-urlencode "query=$1" "$PROM_URL/api/v1/query" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "NaN"' 2>/dev/null || echo "NaN"
}
proc_cpu_ticks() { awk '{print $14+$15}' "/proc/$PROM_PID/stat" 2>/dev/null || echo 0; }
# scrape /metrics once per sample into a temp file, then grep many values from it
# (one HTTP round-trip per sample instead of one per metric).
PROM_SNAP="$OUT_DIR/.snap"
snap_metric() { awk -v m="$1" '$1==m{v=$2} END{print v}' "$PROM_SNAP" 2>/dev/null; }
CLK_TCK="$(getconf CLK_TCK)"

# --- sample loop ------------------------------------------------------------
echo "t_elapsed,cpu_seconds_total,rss_bytes,head_series,samples_appended_total,up,scrape_duration_seconds,scrape_samples_scraped,proc_cpu_seconds" >"$CSV"
START_EPOCH="$(date +%s.%N)"
FAIL_REASON=""
TARGET="$SERIES"; REACHED=0; STEADY_N=0
# Hard wall on wallclock. In AUTO mode allow an extra interval for first-scrape
# jitter to elapse before creation even begins.
MAXWALL="$DURATION"
[[ "$AUTO_INTERVAL" == 1 ]] && MAXWALL=$((DURATION + T))
while :; do
  now="$(date +%s.%N)"
  elapsed="$(awk -v a="$now" -v b="$START_EPOCH" 'BEGIN{printf "%.3f", a-b}')"
  [[ "$(awk -v e="$elapsed" -v m="$MAXWALL" 'BEGIN{print (e>=m)?1:0}')" == 1 ]] && break

  if ! kill -0 "$PROM_PID" 2>/dev/null; then
    FAIL_REASON="prometheus_process_exited"
    echo "    !! prometheus process exited (likely OOM/crash) at t=$elapsed"
    break
  fi

  { curl -fsS "$PROM_URL/metrics" 2>/dev/null || true; } >"$PROM_SNAP"
  cpu="$(snap_metric process_cpu_seconds_total)"; cpu="${cpu:-NaN}"
  rss="$(snap_metric process_resident_memory_bytes)"; rss="${rss:-NaN}"
  head="$(snap_metric prometheus_tsdb_head_series)"; head="${head:-NaN}"
  # appended counter carries a {type="float"} label in v2.x/v3.x — match by prefix.
  appended="$(awk '/^prometheus_tsdb_head_samples_appended_total\{type="float"\}/{v=$2} END{print v}' "$PROM_SNAP")"
  appended="${appended:-NaN}"
  # Aggregate across targets so these stay correct with >1 target:
  #   up      -> min  (any target down is a failure)
  #   sdur    -> max  (worst-case scrape time, our 3rd plotting dimension)
  #   sscr    -> sum  (total samples scraped across targets)
  up="$(api_scalar 'min(up{job="synthetic"})')"
  sdur="$(api_scalar 'max(scrape_duration_seconds{job="synthetic"})')"
  sscr="$(api_scalar 'sum(scrape_samples_scraped{job="synthetic"})')"
  ticks="$(proc_cpu_ticks)"
  pcpu="$(awk -v t="$ticks" -v h="$CLK_TCK" 'BEGIN{printf "%.3f", t/h}')"

  echo "$elapsed,$cpu,$rss,$head,$appended,$up,$sdur,$sscr,$pcpu" >>"$CSV"

  # Steady-state early stop (AUTO mode): once the head has filled to ~target, the
  # one-time creation is done; sample STEADY_TAIL more recurring scrapes then stop.
  if [[ "$AUTO_INTERVAL" == 1 ]]; then
    [[ "$(awk -v h="$head" -v t="$TARGET" 'BEGIN{print (h+0>=0.98*t)?1:0}')" == 1 ]] && REACHED=1
    if [[ "$REACHED" == 1 ]]; then
      STEADY_N=$((STEADY_N+1))
      [[ "$STEADY_N" -ge "$STEADY_TAIL" ]] && { echo "    head reached target; captured ${STEADY_N}s steady-state"; break; }
    fi
  fi
  sleep 1
done

# --- summary ----------------------------------------------------------------
SUMMARY_JSON="$OUT_DIR/summary.json"
SUMMARY_TXT="$OUT_DIR/summary.txt"

# Host inventory for the report.
HOST="$(hostname)"
NCPU_TOTAL="$(nproc)"
CPU_MODEL="$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
MEM_TOTAL_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"

python3 - "$CSV" "$SUMMARY_JSON" "$SUMMARY_TXT" <<PY
import csv, json, sys, math
csv_path, json_path, txt_path = sys.argv[1], sys.argv[2], sys.argv[3]

meta = dict(
    run_id="$RUN_ID",
    prom_version="$PROM_VERSION",
    prom_bin="$PROM_BIN",
    host="$HOST",
    cpu_model="""$CPU_MODEL""".strip(),
    ncpu_total=int("$NCPU_TOTAL"),
    mem_total_gib=round(int("$MEM_TOTAL_KB")/1048576, 1),
    prom_cores="$PROM_CORES", prom_ncores=int("$PROM_NCORES"),
    gen_cores="$GEN_CORES",
    series_target=int("$SERIES"),
    interval="$INTERVAL", timeout="$TIMEOUT",
    duration_s=int("$DURATION"),
    extra_labels=int("$EXTRA_LABELS"),
    gen_payload_bytes=int("${GEN_BYTES:-0}"),
    fail_reason="$FAIL_REASON",
)

def f(x):
    try:
        v=float(x)
        return v if math.isfinite(v) else None
    except: return None

rows=[]
with open(csv_path) as fh:
    for r in csv.DictReader(fh):
        rows.append(r)

warm=int("$WARMUP")
usable=[r for r in rows if f(r["cpu_seconds_total"]) is not None]
result=dict(meta=meta, n_samples=len(rows), n_usable=len(usable))

def delta(b, a, key):
    bv, av = f(b[key]), f(a[key])
    return (bv-av) if (bv is not None and av is not None) else None

target=meta["series_target"]
heads=[f(r["head_series"]) for r in usable if f(r["head_series"]) is not None]
rsss=[f(r["rss_bytes"]) for r in usable if f(r["rss_bytes"]) is not None]
sdurs=[f(r["scrape_duration_seconds"]) for r in usable if f(r["scrape_duration_seconds"]) is not None]
ups=[f(r["up"]) for r in usable if f(r["up"]) is not None]
sscr=[f(r["scrape_samples_scraped"]) for r in usable if f(r["scrape_samples_scraped"]) is not None]

# --- creation window: CPU burned while the head fills. Series creation IS the
# ingest work (parse + label intern + index posting + head append + WAL), and
# samples_appended only commits at scrape end, so head_series is the live signal.
# This is well-defined at every cardinality, including partial fills before OOM.
istart=iend=None
for i,r in enumerate(usable):
    hv=f(r["head_series"])
    if hv is None: continue
    if istart is None and hv>0: istart=i
    if hv>=0.98*target: iend=i; break
creation_reached = iend is not None
if istart is not None and iend is None:
    iend=len(usable)-1   # never fully filled (timeout wall or OOM) -> measure the climb

if heads:
    interval_s=float("$INTERVAL".rstrip('s') or 1)
    measured=dict(
        peak_head_series=int(max(heads)),
        peak_rss_gib=round(max(rsss)/(1<<30),2) if rsss else None,
        max_scrape_samples_scraped=int(max(sscr)) if sscr else None,
        min_up=min(ups) if ups else None,
        max_scrape_duration_s=round(max(sdurs),3) if sdurs else None,
        sustained_1s=(bool(ups) and min(ups)==1 and bool(sdurs) and max(sdurs) < interval_s),
        creation_reached=creation_reached,
        creation_scrape_duration_s=round(max(sdurs),3) if sdurs else None,
    )
    if istart is not None and iend is not None and iend>istart:
        a=usable[istart]; b=usable[iend]
        dt=delta(b,a,"t_elapsed") or 0.0
        dcpu=delta(b,a,"cpu_seconds_total")
        dhead=delta(b,a,"head_series")            # series created in the window
        measured.update(
            window_s=round(dt,2),
            series_created=int(dhead) if dhead is not None else None,
            cpu_seconds_used=round(dcpu,3) if dcpu is not None else None,
            ingest_series_per_s=round(dhead/dt,1) if (dhead is not None and dt>0) else None,
            cpu_cores_used=round(dcpu/dt,3) if (dcpu is not None and dt>0) else None,
            cpu_pct_of_prom_allocation=round(100*(dcpu/dt)/meta["prom_ncores"],1) if (dcpu is not None and dt>0) else None,
            cpu_seconds_per_million_series=round(dcpu/(dhead/1e6),4) if (dcpu is not None and dhead and dhead>0) else None,
        )
    # --- steady-state bonus: recurring re-append after the head is full (only
    # resolvable when the scrape interval is short enough to fit >=2 post scrapes).
    if creation_reached:
        steady=usable[(iend+1):]
        steady_ing=[r for r in steady if f(r["samples_appended_total"]) is not None]
        if len(steady_ing)>=2:
            sa,sb=steady_ing[0],steady_ing[-1]
            sdt=delta(sb,sa,"t_elapsed") or 0.0
            sdcpu=delta(sb,sa,"cpu_seconds_total")
            sdsamp=delta(sb,sa,"samples_appended_total")
            # Exclude the creation scrape's value, which lingers in scrape_duration
            # for a few samples after the head fills, until the next re-append scrape.
            cval=max(sdurs) if sdurs else None
            s_sdurs=[f(r["scrape_duration_seconds"]) for r in steady
                     if f(r["scrape_duration_seconds"]) is not None
                     and (cval is None or abs(f(r["scrape_duration_seconds"])-cval)>1e-6)]
            measured.update(
              steady_window_s=round(sdt,2),
              steady_cpu_cores=round(sdcpu/sdt,3) if (sdcpu is not None and sdt>0) else None,
              steady_cpu_s_per_million=round(sdcpu/(sdsamp/1e6),4) if (sdcpu is not None and sdsamp and sdsamp>0) else None,
              steady_scrape_duration_s=round(max(s_sdurs),3) if s_sdurs else None,
            )
    result["measured"]=measured

with open(json_path,"w") as fh: json.dump(result, fh, indent=2)

m=result.get("measured",{})
lines=[
 f"Run:        {meta['run_id']}",
 f"Host:       {meta['host']}  ({meta['ncpu_total']} vCPU, {meta['mem_total_gib']} GiB)",
 f"CPU:        {meta['cpu_model']}",
 f"Prometheus: {meta['prom_version']}  pinned to cores {meta['prom_cores']} ({meta['prom_ncores']} cores)",
 f"Target:     {meta['series_target']:,} series @ {meta['interval']} (payload {meta['gen_payload_bytes']/(1<<20):.1f} MiB)",
 f"Fail:       {meta['fail_reason'] or 'none'}",
 "-"*64,
]
if m:
    lines += [
     f"Peak head series:         {m['peak_head_series']:,}" if m.get('peak_head_series') else "Peak head series:         n/a",
     f"Creation reached target:  {m.get('creation_reached')}",
     f"Peak RSS:                 {m['peak_rss_gib']} GiB" if m.get('peak_rss_gib') else "",
     f"1s scrape sustained:      {m['sustained_1s']} (min up={m.get('min_up')}, max scrape={m.get('max_scrape_duration_s')}s)",
     "-"*64,
     "CREATION (ingest of N new series):",
     f"  window:                 {m.get('window_s')} s" if m.get('window_s') is not None else "",
     f"  series created:         {m['series_created']:,}" if m.get('series_created') else "",
     f"  CPU used for ingest:    {m['cpu_cores_used']} cores ({m.get('cpu_pct_of_prom_allocation')}% of {meta['prom_ncores']} allocated)" if m.get('cpu_cores_used') is not None else "",
     f"  CPU per 1M series:      {m['cpu_seconds_per_million_series']} cpu-seconds" if m.get('cpu_seconds_per_million_series') is not None else "",
     f"  ingest rate:            {m['ingest_series_per_s']:,.0f} series/s" if m.get('ingest_series_per_s') else "",
     f"  scrape duration (1x):   {m.get('creation_scrape_duration_s')} s   <- worst-case scrape time (3rd plot axis)",
    ]
    if m.get("steady_cpu_cores") is not None:
        lines += [
         "STEADY-STATE (recurring re-append):",
         f"  CPU:                    {m.get('steady_cpu_cores')} cores",
         f"  CPU per 1M samples:     {m.get('steady_cpu_s_per_million')} cpu-seconds" if m.get('steady_cpu_s_per_million') is not None else "",
         f"  scrape duration:        {m.get('steady_scrape_duration_s')} s",
        ]
else:
    lines += ["No usable samples (Prometheus may have failed immediately)."]
open(txt_path,"w").write("\n".join(l for l in lines if l)+"\n")
print("\n".join(l for l in lines if l))
PY

echo
echo "==> wrote $OUT_DIR/{samples.csv,summary.json,summary.txt,prometheus.log,metricgen.log}"
