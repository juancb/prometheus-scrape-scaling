# FAQ — Prometheus ingest scaling plot & results

Companion to `REPORT.md`, `scale-rate-vs-cores.png`, and the data in
`scale.csv` / `scale-summary.csv`.

---

### Q. What are the red triangles on the plot?

They are **under-saturated points reported as lower bounds**, at **48 and 56
cores**. A point becomes a red hollow down-triangle (▽) when *none* of its 5
replicates reached our saturation gate of **≥ 85% CPU of the allotted cores**.

In those runs the interval controller never pushed Prometheus to its ingest
ceiling — it settled at a loose scrape interval with the CPU only ~27–38% busy
(see the `mean_cpu_pct` column). So the measured rate is a **floor, not a peak**:
the true capacity at 48/56 cores is *at least* that value, probably much higher.
We draw them as triangles (not filled circles) precisely so they are not mistaken
for measured peaks. Filled blue circles, by contrast, are CPU-saturated measured
peaks.

---

### Q. Was GOMAXPROCS the only limit, or was taskset/cpuset also applied — with GOMAXPROCS aligned to it?

**Both were applied and aligned.** For each core count `N`, Prometheus was launched as:

```sh
GOMAXPROCS=N  taskset -c 0-(N-1)  prometheus …
```

- `taskset -c 0-(N-1)` sets a **kernel CPU-affinity mask** (cpuset-style) so the
  Linux scheduler may only run Prometheus on vCPUs `0 … N-1`. This is a hard cap
  enforced by the OS, independent of the Go runtime.
- `GOMAXPROCS=N` caps how many OS threads the Go runtime executes in parallel,
  set to the **same width** so the runtime matches the cpuset and doesn't
  oversubscribe.

So GOMAXPROCS was *not* the only limit. We deliberately did **not** pin one thread
per core (`taskset 0-(N-1)` gives the scheduler a pool of N vCPUs to move threads
within — "we are not smarter than the Linux scheduler"). The synthetic exporters
ran separately and unconstrained (`GOMAXPROCS=1 taskset -c 0-63`, ~0 CPU each), so
the CPU we attribute to Prometheus is genuinely Prometheus's ingest work.

---

### Q. What's with the error bars at 32 cores but (apparently) not elsewhere?

The error bars are **95% confidence intervals over the *saturated* replicates**.
They exist at every blue point — they're just different sizes, and at 4–24 cores
they're too small to see:

| cores | saturated reps | 95% CI half-width | why it looks the way it does |
|------:|:--------------:|------------------:|---|
| 4–16 | 5/5 | ±0.14–0.15 M/s | bars present but ~invisible on a 0–50 M/s axis |
| 24 | 5/5 | ±0.47 M/s | still tiny |
| **32** | **2/5** | **±8.1 M/s** | **big & visible** |
| 40 | 1/5 | — | single point → CI undefined → no bar |
| 48, 56 | 0/5 | — | not saturated → red triangles, not on the CI series |
| 64 | 1/5 | — | single point → no bar |

The conspicuous bar at 32 cores comes from a double whammy: only **2** of the 5
replicates saturated, and those two disagreed (19.35 vs 20.62 M/s). With just 2
samples the Student-t multiplier for 1 degree of freedom is **12.7×**, which
inflates a modest spread into a ±8 M/s interval. It's a small-sample artifact, not
extra real-world variability — and it's a direct symptom of the controller problem
in §6 of the report (the controller only reliably saturated through 24 cores).

So: tight, trustworthy CIs at 4–24 cores; a wide CI at 32 (n=2); no CI at 40/64
(n=1); and triangles instead of CIs at 48/56 (n=0).

---

### Q. How many runs were there for each core count?

**5 cold-restart replicates per core count** (fresh tmpfs TSDB each time), across
**9 core counts → 45 runs total**. "Saturated reps" (the `n_saturated` column)
counts how many of those 5 actually reached ≥85% CPU and thus contribute to a
*peak* rather than a lower bound: 5/5 through 24 cores, then 2, 1, 0, 0, 1 as the
controller lost the ability to saturate the larger sets.

---

### Q. What do "samples/s" and "series" mean here, and why is rate = series ÷ interval?

A **series** is one unique time-series (a metric with a fixed label set). A
**sample** is one (timestamp, value) data point appended to a series. Every scrape
appends one sample to each active series, so one full scrape of `S` series
produces `S` samples. If you scrape every `I` seconds, the steady ingest rate is
`S / I` samples/s. We measured it directly from
`prometheus_tsdb_head_samples_appended_total` rather than computing it, but that's
why a smaller interval (more frequent scrapes) means a higher rate — up to the
point where the CPU saturates or scrapes overrun the interval.

---

### Q. What does "saturated" mean, and why gate on 85% CPU?

"Saturated" = Prometheus is CPU-bound on its allotted cores, i.e. it's actually at
its ingest ceiling for that core count. We require a replicate to have reached
**≥ 85% CPU of its N cores** to count its rate as a *peak*. Below that threshold
the bottleneck wasn't CPU — the controller simply hadn't tightened the scrape
interval enough — so the rate understates capacity. 85% leaves headroom for the
small fraction of time spent in scrape I/O and scheduling while still demanding
the box be genuinely busy.

---

### Q. Why does the blue curve fall below the grey dashed "ideal linear" line?

The grey dashed line is **perfect strong scaling** — what you'd get if N cores
delivered exactly N× the per-core rate measured at 4 cores. The real curve falls
below it because more cores means more **contention**: TSDB head locks, memory-
bandwidth pressure, allocator/GC, and — past 32 cores — **SMT siblings sharing
execution units** (see next question). The right-hand panel shows the same thing
as a falling per-core efficiency. This sub-linear shape is expected and normal;
the useful question isn't "is it linear?" (it never is) but "does it clear 10 M/s,
and with how much margin?" — which it does, at 16 cores.

---

### Q. Why does efficiency drop sharply after 32 cores?

Two compounding reasons:

1. **SMT boundary.** This box has 32 physical cores, each with 2 hardware threads.
   vCPUs 0–31 are one thread per physical core; vCPUs 32–63 are their siblings. So
   `taskset 0-(N-1)` adds *independent physical cores* up to N=32, but beyond 32 it
   starts adding *SMT siblings* onto already-busy cores. A sibling typically yields
   only ~20–30% extra throughput, so per-core efficiency necessarily falls in that
   region — this is hardware, not Prometheus.
2. **Controller under-saturation (§6 of the report).** Above 32 cores the interval
   controller often failed to saturate the CPU, so those points understate
   capacity. The 48/56-core numbers in particular are lower bounds.

Because these two effects overlap in the 40–64 core range, that part of the curve
shouldn't be read as a clean efficiency measurement. The trustworthy efficiency
trend is the 4–32 core (all-physical-core) segment: 0.865 → 0.624 M/s/core.

---

### Q. What are the grey dashed and green dotted lines?

- **Grey dashed** = ideal linear scaling, anchored at the 4-core rate
  (0.865 M/s/core). It's the "no contention" reference, not a fit.
- **Green dotted** = the **10 M samples/s target**. The blue curve crosses it
  between 8 and 16 cores; 16 cores clears it with a measured 11.69 M/s.

---

### Q. Does the tmpfs TSDB (RAM-backed, no swap) change the results?

It affects the **memory ceiling**, not the per-core *rate*. The TSDB lives in
`/tmp`, which is RAM-backed, and there's no swap — so TSDB pages compete with
Prometheus's own RSS for the 124 GiB of physical memory. That sets an OOM ceiling
(we saw it earlier around ~76 M series in a different run) and is why RSS climbs
to ~45 GiB at 25.6 M series here. It does **not** speed up ingest: the head block
and WAL writes are not the bottleneck at these rates — CPU is. The rate numbers
would look the same on fast local SSD; only the upper cardinality limit would
move.

---

### Q. Is this one Prometheus process, or a cluster?

**One single Prometheus 3.12.0 process**, scaled by giving it more cores on one
machine (vertical scaling). The 10 M/s answer is per-process. Horizontal sharding
(multiple Prometheus / agent instances) is a separate axis not studied here.

---

### Q. Why hold series-per-core constant instead of total series?

To make it a clean **strong-scaling** experiment. If we'd fixed *total* series and
added cores, we'd be measuring "does more CPU help a fixed workload" (latency
scaling) and would hit a point where extra cores have nothing to do. By fixing
*per-core* cardinality (400k series/core), ideal hardware would trace a flat
per-core line and a straight total-throughput line — so every deviation is
directly attributable to contention. It also keeps each core's working set
comparable across the sweep.

---

### Q. How much memory does this take?

RSS scales ~linearly with head series at roughly **1.8–2.0 KB per active series**
on this build: 13 GiB at 6.4 M series (16 cores), 18.7 GiB at 9.6 M (24 cores),
up to ~45 GiB at 25.6 M (64 cores). Budget memory by your target cardinality, not
by core count.

---

### Q. Can I trust the single-replicate 64-core = 23.55 M/s number?

Treat it as **suggestive, not confident**. It's one saturated replicate (95% CPU)
out of five; the other four under-saturated. It's consistent with the trend
(capacity keeps rising past 32 cores) and with the 32-core saturated mean
(~20 M/s), but it has no error bar and shouldn't be quoted as *the* 64-core peak.
A bisection-controller re-run (§6) would turn it into a real measurement.

---

### Q. What would you do differently next time?

1. **Bisection interval controller** to reliably find the saturated edge at high
   target counts (the main fix — turns 40–64c lower bounds into measured peaks).
2. **Split the sweep at the 32-core SMT boundary** and report the physical-core
   curve and SMT-packing curve separately, so the two effects aren't conflated.
3. **More replicates (e.g. 8–10)** at the high-core points where variance is
   larger, to tighten CIs without the small-sample t-multiplier blowup.
4. Optionally vary **per-core cardinality** as a second factor to check the result
   isn't specific to 400k series/core.
