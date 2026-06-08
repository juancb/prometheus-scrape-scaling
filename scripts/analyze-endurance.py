#!/usr/bin/env python3
"""
Analyze an endurance-compaction run: time series of ingest, CPU, memory, and
scrape health across the first 2h-block head compaction, to answer "does
compaction disrupt 10M/s ingest?".

Reads results/endurance__*/endurance.csv (or $CSV), marks compaction events
(where compactions_total or head_truncations_total increments), prints a
summary, and renders a stacked time-series plot.

Env: CSV (default: latest), OUT (default: csv dir)
"""
import csv
import glob
import math
import os
import statistics
import sys


def find_csv():
    if os.environ.get("CSV"):
        return os.environ["CSV"]
    c = sorted(glob.glob("results/endurance__*/endurance.csv"), key=os.path.getmtime)
    if not c:
        sys.exit("no endurance.csv found and $CSV unset")
    return c[-1]


def fnum(x, d=float("nan")):
    try:
        return float(x)
    except (TypeError, ValueError):
        return d


def main():
    csv_path = find_csv()
    out_dir = os.environ.get("OUT", os.path.dirname(csv_path))
    rows = list(csv.DictReader(open(csv_path)))
    if len(rows) < 3:
        sys.exit(f"not enough rows in {csv_path} yet ({len(rows)})")

    t = [fnum(r["elapsed_s"]) / 60.0 for r in rows]          # minutes
    rate = [fnum(r["ingest_rate"]) / 1e6 for r in rows]       # M/s
    cpu = [fnum(r["cpu_pct16"]) for r in rows]
    rss = [fnum(r["rss_gib"]) for r in rows]
    head = [fnum(r["head_series"]) / 1e6 for r in rows]
    span = [fnum(r["head_span_s"]) / 3600.0 for r in rows]    # hours
    scrape = [fnum(r["scrape_max_s"]) for r in rows]
    minup = [fnum(r["min_up"]) for r in rows]
    disk = [fnum(r["tsdb_disk_mib"]) / 1024.0 for r in rows]  # GiB
    comp = [fnum(r["compactions_total"]) for r in rows]
    trunc = [fnum(r["head_truncations_total"]) for r in rows]

    # compaction event times (minutes) where the counter steps up
    def steps(series):
        out = []
        for i in range(1, len(series)):
            if not math.isnan(series[i]) and not math.isnan(series[i - 1]) and series[i] > series[i - 1]:
                out.append(t[i])
        return out
    interval = float(os.environ.get("INTERVAL", 0.64))   # scrape_timeout == interval
    comp_ev = steps(comp)
    trunc_ev = steps(trunc)
    # compaction ONSET: the head becomes compactable when its span exceeds 3h
    # (1.5 x 2h). The compactions_total counter only ticks on *completion*, so if
    # the compaction is still running at the end it never shows up there — mark
    # the onset from the span crossing instead.
    onset = next((t[i] for i in range(len(rows))
                  if not math.isnan(span[i]) and span[i] >= 3.0), None)
    events = sorted(set(comp_ev) | set(trunc_ev) | ({onset} if onset else set()))

    # steady-state ingest = median over the pre-onset window (true steady state)
    pre = [rate[i] for i in range(1, len(rows))
           if not math.isnan(rate[i]) and (onset is None or t[i] < onset)]
    post = [rate[i] for i in range(1, len(rows))
            if not math.isnan(rate[i]) and onset is not None and t[i] >= onset]
    steady = statistics.median(pre) if pre else float("nan")

    worst_scrape = max((s for s in scrape if not math.isnan(s)), default=float("nan"))
    worst_scrape_t = t[scrape.index(worst_scrape)] if not math.isnan(worst_scrape) else float("nan")
    # scrapes that exceeded the timeout (== interval) => that scrape failed / samples dropped
    breaches = [(t[i], scrape[i]) for i in range(len(rows))
                if not math.isnan(scrape[i]) and scrape[i] > interval]
    pre_breach = [b for b in breaches if onset is None or b[0] < onset]
    post_breach = [b for b in breaches if onset is not None and b[0] >= onset]

    print(f"# {csv_path}")
    print(f"samples: {len(rows)}   span: {t[-1]:.1f} min   scrape timeout: {interval}s")
    print(f"head series: {head[-1]:.2f} M   peak RSS: {max(rss):.1f} GiB   "
          f"TSDB on disk: {disk[-1]:.2f} GiB")
    print(f"head span reached: {max(span):.2f} h")
    print(f"compactions COMPLETED: {comp[-1]:.0f}   head_truncations: {trunc[-1]:.0f}")
    if onset is not None:
        print(f"\n-- compaction onset @ {onset:.1f} min (head span hit 3h) --")
        print(f"steady ingest (pre-onset median):  {steady:.2f} M/s")
        if post:
            print(f"ingest during compaction:          median {statistics.median(post):.2f} "
                  f"M/s, min {min(post):.2f} M/s  ({100*(statistics.median(post)-steady)/steady:+.0f}% median)")
        rss_pre = max((rss[i] for i in range(len(rows)) if t[i] < onset and not math.isnan(rss[i])), default=float('nan'))
        print(f"RSS: {rss_pre:.0f} GiB pre-onset -> {max(rss):.0f} GiB peak during compaction "
              f"(box has 124 GiB)")
        if comp[-1] == 0:
            print("compaction did NOT complete within the run (still running at shutdown; "
                  "block left as .tmp-for-creation)")
    print(f"\nworst scrape latency: {worst_scrape:.2f} s @ {worst_scrape_t:.1f} min "
          f"(timeout is {interval}s)")
    print(f"scrapes over timeout: {len(breaches)} ticks  "
          f"(pre-onset {len(pre_breach)}, during compaction {len(post_breach)})  "
          f"-> each is a failed scrape / dropped samples")
    print("NB: instantaneous min(up) sampling can read 1 even when scrapes are "
          "failing between ticks; scrape_max > timeout is the reliable drop signal.")

    render(t, rate, cpu, rss, head, span, scrape, minup, disk, events, steady, onset, interval, out_dir, csv_path)


def render(t, rate, cpu, rss, head, span, scrape, minup, disk, events, steady, onset, interval, out_dir, csv_path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(4, 1, figsize=(12, 12), sharex=True)

    def mark(ax):
        if onset is not None:
            ax.axvspan(onset, t[-1], color="#d62728", alpha=0.07, zorder=0)
            ax.axvline(onset, color="#d62728", ls="--", lw=1.6, alpha=0.9, zorder=1)
        for e in events:
            if onset is None or abs(e - onset) > 1e-6:
                ax.axvline(e, color="#d62728", ls=":", lw=1.0, alpha=0.6, zorder=1)

    # 1) ingest rate
    ax = axes[0]
    ax.plot(t[1:], rate[1:], color="#1f77b4", lw=1.3)
    ax.axhline(10.0, color="#2ca02c", ls=":", lw=1.5, label="10 M/s target")
    if not math.isnan(steady):
        ax.axhline(steady, color="#888", ls="--", lw=1, label=f"median {steady:.2f} M/s")
    mark(ax)
    ax.set_ylabel("ingest (M samp/s)"); ax.legend(fontsize=8, loc="lower right")
    ax.set_title("Ingest rate — red line = compaction onset (head span=3h), shaded = compaction in progress")
    ax.grid(True, alpha=0.3); ax.set_ylim(bottom=0)

    # 2) scrape latency + min_up
    ax = axes[1]
    ax.plot(t, scrape, color="#9467bd", lw=1.2, label="max scrape duration (s)")
    ax.axhline(interval, color="#d62728", ls=":", lw=1.2, label=f"scrape timeout {interval}s")
    ax.set_ylabel("scrape dur (s)", color="#9467bd"); ax.grid(True, alpha=0.3)
    ax.set_ylim(bottom=0); mark(ax)
    ax2 = ax.twinx()
    ax2.plot(t, minup, color="#ff7f0e", lw=1.2)
    ax2.set_ylabel("min(up)", color="#ff7f0e"); ax2.set_ylim(-0.05, 1.1)
    ax.set_title("Scrape health: latency (purple) and min(up) (orange) — dips = dropped scrapes")
    ax.legend(fontsize=8, loc="upper left")

    # 3) CPU + RSS
    ax = axes[2]
    ax.plot(t, cpu, color="#d62728", lw=1.2, label="CPU % of 16 cores")
    ax.set_ylabel("CPU % (16c)", color="#d62728"); ax.grid(True, alpha=0.3)
    ax.set_ylim(bottom=0); mark(ax)
    ax3 = ax.twinx()
    ax3.plot(t, rss, color="#1f77b4", lw=1.2)
    ax3.set_ylabel("RSS (GiB)", color="#1f77b4")
    ax.set_title("CPU (red) and resident memory (blue) — watch for compaction spikes")
    ax.legend(fontsize=8, loc="upper left")

    # 4) head span toward 3h, head series, disk
    ax = axes[3]
    ax.plot(t, span, color="#2ca02c", lw=1.4, label="head time span (h)")
    ax.axhline(3.0, color="#2ca02c", ls=":", lw=1.2, label="3h compaction threshold")
    ax.set_ylabel("head span (h)", color="#2ca02c"); ax.grid(True, alpha=0.3)
    ax.set_ylim(bottom=0); mark(ax)
    ax4 = ax.twinx()
    ax4.plot(t, disk, color="#8c564b", lw=1.3, label="TSDB on disk (GiB)")
    ax4.plot(t, head, color="#17becf", lw=1.0, alpha=0.7, label="head series (M)")
    ax4.set_ylabel("disk GiB / head M")
    ax.set_title("Head time-span sawtooth (compaction at 3h), TSDB disk growth, head series")
    ax.legend(fontsize=8, loc="upper left"); ax4.legend(fontsize=8, loc="lower right")
    ax.set_xlabel("elapsed (minutes)")

    fig.suptitle("Prometheus 3.12.0 @ 10 M/s endurance — first 2h-block compaction (16c, 6.4M series, NVMe)",
                 fontsize=12, y=0.995)
    fig.tight_layout()
    p = os.path.join(out_dir, "endurance-timeseries.png")
    fig.savefig(p, dpi=125, bbox_inches="tight")
    print(f"\nwrote {p}")
    plt.close(fig)


if __name__ == "__main__":
    main()
