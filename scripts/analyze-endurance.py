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
    comp_ev = steps(comp)
    trunc_ev = steps(trunc)
    events = sorted(set(comp_ev) | set(trunc_ev))

    # steady-state ingest from the first 80% of samples that have a rate
    valid_rate = [r for r in rate[1:] if not math.isnan(r)]
    steady = statistics.median(valid_rate) if valid_rate else float("nan")

    # scrape latency / min_up health, and worst dips
    dropped = [(t[i], minup[i]) for i in range(len(rows)) if not math.isnan(minup[i]) and minup[i] < 0.999]
    worst_scrape = max((s for s in scrape if not math.isnan(s)), default=float("nan"))
    worst_scrape_t = t[scrape.index(worst_scrape)] if not math.isnan(worst_scrape) else float("nan")

    print(f"# {csv_path}")
    print(f"samples: {len(rows)}   span: {t[-1]:.1f} min")
    print(f"steady ingest (median): {steady:.2f} M/s")
    print(f"head series: {head[-1]:.2f} M   final RSS: {rss[-1]:.1f} GiB   "
          f"TSDB on disk: {disk[-1]:.2f} GiB")
    print(f"head span reached: {max(span):.2f} h  (compaction fires at 3h / 1.5x2h)")
    print(f"compactions_total: {comp[-1]:.0f}   head_truncations_total: {trunc[-1]:.0f}")
    if events:
        print(f"compaction/truncation events at (min): "
              + ", ".join(f"{e:.1f}" for e in events))
        # ingest impact: compare median rate within +/-1 min of an event vs steady
        for e in events:
            near = [rate[i] for i in range(1, len(rows))
                    if abs(t[i] - e) <= 1.0 and not math.isnan(rate[i])]
            if near:
                m = statistics.median(near)
                print(f"  @ {e:.1f} min: ingest {m:.2f} M/s "
                      f"({100*(m-steady)/steady:+.1f}% vs steady)")
    else:
        print("no compaction/head-truncation events captured yet "
              "(run longer — first head compaction is ~3h in)")
    print(f"worst scrape latency: {worst_scrape:.3f} s @ {worst_scrape_t:.1f} min")
    if dropped:
        print(f"min(up)<1 (possible dropped scrapes) at {len(dropped)} ticks; "
              f"first @ {dropped[0][0]:.1f} min (min_up={dropped[0][1]:.3f})")
    else:
        print("min(up)==1 throughout — no dropped scrapes")

    render(t, rate, cpu, rss, head, span, scrape, minup, disk, events, steady, out_dir, csv_path)


def render(t, rate, cpu, rss, head, span, scrape, minup, disk, events, steady, out_dir, csv_path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(4, 1, figsize=(12, 12), sharex=True)

    def mark(ax):
        for e in events:
            ax.axvline(e, color="#d62728", ls="--", lw=1.3, alpha=0.8, zorder=1)

    # 1) ingest rate
    ax = axes[0]
    ax.plot(t[1:], rate[1:], color="#1f77b4", lw=1.3)
    ax.axhline(10.0, color="#2ca02c", ls=":", lw=1.5, label="10 M/s target")
    if not math.isnan(steady):
        ax.axhline(steady, color="#888", ls="--", lw=1, label=f"median {steady:.2f} M/s")
    mark(ax)
    ax.set_ylabel("ingest (M samp/s)"); ax.legend(fontsize=8, loc="lower right")
    ax.set_title("Ingest rate (red dashes = compaction / head-truncation events)")
    ax.grid(True, alpha=0.3); ax.set_ylim(bottom=0)

    # 2) scrape latency + min_up
    ax = axes[1]
    ax.plot(t, scrape, color="#9467bd", lw=1.2, label="max scrape duration (s)")
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
