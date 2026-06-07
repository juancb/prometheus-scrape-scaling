#!/usr/bin/env python3
"""Plot ingest benchmark ramps.

Reads one or more ramp aggregate CSVs (results/ramp__*.csv) and renders:
  - ingest_3d.png   : 3D view  X=series, Y=CPU per 1M series, Z=worst-case scrape time
  - cpu_vs_series.png, scrape_vs_series.png, rss_vs_series.png : 2D projections

The 3D axes are the three the experiment cares about:
  X "requests" -> series (samples scraped per scrape)
  Y CPU        -> cpu-seconds per 1,000,000 series ingested (creation cost)
  Z scrape     -> worst-case scrape duration for the run (the creation scrape)

OOM / failed runs are marked with a red X.

Usage: python3 scripts/plot.py results/ramp__v3.12.0__*.csv results/ramp__apt-2.45.3__*.csv
"""
import csv, sys, os, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D  # noqa: F401

OUT = os.environ.get("OUT", "results/plots")
# Drop CPU points above this cpu-s/1M — they are creation-contaminated (a long
# scrape that never committed samples inside the measure window). Set high to
# disable. Scrape/RSS curves are unaffected; they keep every row.
CPM_MAX = float(os.environ.get("CPM_MAX", "1e9"))
os.makedirs(OUT, exist_ok=True)


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def load(path):
    label = os.path.basename(path).replace("ramp__", "").replace(".csv", "")
    label = label.rsplit("__", 1)[0]  # drop timestamp
    rows = []
    with open(path) as fh:
        for r in csv.DictReader(fh):
            rows.append(r)
    return label, rows


def series_axis(r):
    # growth CSVs key on head_series; ramp CSVs on series
    return num(r.get("head_series")) or num(r.get("series"))


def cpu_axis(r):
    # cpu-seconds per million samples/series (interval-independent ingest cost).
    # Returns None for creation-contaminated outliers so they drop from CPU/3D plots.
    v = (num(r.get("cpu_s_per_million"))
         or num(r.get("cpu_s_per_million_series"))
         or num(r.get("cpu_cores_used")))
    if v is not None and v > CPM_MAX:
        return None
    return v


def scrape_axis(r):
    # worst-case scrape time across targets
    return num(r.get("worst_scrape_s")) or num(r.get("creation_scrape_s")) or num(r.get("max_scrape_s"))


def avg_cores(r):
    # Sustained cores used for ingest (avg over the scrape duty cycle). With many
    # targets, Prometheus staggers scrapes across the interval, so this average is
    # the honest "cores for ingest" figure (it rises as scrapes lengthen + overlap).
    return num(r.get("cpu_cores")) or num(r.get("cpu_cores_used"))


def failed(r):
    return bool((r.get("fail_reason") or "").strip())


def main(paths):
    files = []
    for p in paths:
        files.extend(sorted(glob.glob(p)))
    if not files:
        print("no CSV files matched:", paths); sys.exit(1)

    datasets = [load(p) for p in files]
    colors = plt.cm.tab10.colors

    # ---- 3D ----
    fig = plt.figure(figsize=(11, 8))
    ax = fig.add_subplot(111, projection="3d")
    for i, (label, rows) in enumerate(datasets):
        xs, ys, zs = [], [], []
        fx, fy, fz = [], [], []
        for r in rows:
            x, y, z = series_axis(r), cpu_axis(r), scrape_axis(r)
            if None in (x, y, z):
                continue
            if failed(r):
                fx.append(x); fy.append(y); fz.append(z)
            xs.append(x); ys.append(y); zs.append(z)
        if xs:
            ax.plot(xs, ys, zs, "-o", color=colors[i % 10], label=label, markersize=5)
        if fx:
            ax.scatter(fx, fy, fz, color="red", marker="X", s=140, label=f"{label} OOM/fail")
    ax.set_xlabel("series (requests)")
    ax.set_ylabel("CPU-s per 1M series")
    ax.set_zlabel("worst-case scrape (s)")
    ax.set_title("Prometheus ingest: series x CPU x scrape time")
    ax.legend(loc="upper left", fontsize=8)
    fig.tight_layout()
    fig.savefig(f"{OUT}/ingest_3d.png", dpi=130)
    print(f"wrote {OUT}/ingest_3d.png")

    # ---- 2D projections ----
    def plot2d(yfn, ylabel, fname, logy=False):
        fig, ax = plt.subplots(figsize=(9, 5.5))
        for i, (label, rows) in enumerate(datasets):
            xs, ys = [], []
            fx, fy = [], []
            for r in rows:
                x, y = series_axis(r), yfn(r)
                if None in (x, y):
                    continue
                xs.append(x); ys.append(y)
                if failed(r):
                    fx.append(x); fy.append(y)
            if xs:
                ax.plot(xs, ys, "-o", color=colors[i % 10], label=label)
            if fx:
                ax.scatter(fx, fy, color="red", marker="X", s=120, zorder=5,
                           label=f"{label} OOM/fail")
        ax.set_xscale("log")
        if logy:
            ax.set_yscale("log")
        ax.set_xlabel("series (requests)")
        ax.set_ylabel(ylabel)
        ax.grid(True, which="both", alpha=0.3)
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(f"{OUT}/{fname}", dpi=130)
        print(f"wrote {OUT}/{fname}")

    plot2d(cpu_axis, "CPU-s per 1M samples (ingest cost)", "cpu_vs_series.png")
    plot2d(scrape_axis, "worst-case scrape duration (s)", "scrape_vs_series.png", logy=True)
    plot2d(avg_cores, "sustained cores used for ingest", "cores_vs_series.png")
    plot2d(lambda r: num(r.get("rss_gib")) or num(r.get("peak_rss_gib")),
           "RSS (GiB)", "rss_vs_series.png")


if __name__ == "__main__":
    args = sys.argv[1:] or ["results/ramp__*.csv"]
    main(args)
