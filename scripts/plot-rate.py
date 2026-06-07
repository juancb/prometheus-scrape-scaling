#!/usr/bin/env python3
"""Plot the rate-max sweep (scripts/rate-max.sh output).

We care about three things only (scrape duration is intentionally omitted; the
ingest rate already captures throughput):
  - metric ingest rate  = samples ACTUALLY appended per second
  - CPU utilization      = % of the cores Prometheus was given
  - memory used          = RSS (GiB), against total system RAM

Renders:
  ratemax_rate_vs_series.png   headline: ingest rate vs cardinality, peak marked
  ratemax_cpu_vs_series.png    CPU utilization vs cardinality
  ratemax_rss_vs_series.png    RSS vs cardinality, with total-RAM ceiling
  ratemax_3d.png               X=ingest rate, Y=CPU util %, Z=RSS GiB (color=series)

Usage: python3 scripts/plot-rate.py results/ratemax__v3.12.0__*/ratemax.csv
"""
import csv, sys, os, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D  # noqa: F401

OUT = os.environ.get("OUT", "results/plots")
NCORES = int(os.environ.get("NCORES", "16"))
RAM_GIB = float(os.environ.get("RAM_GIB", "126"))
TITLE_SUFFIX = f"  [{NCORES} vCPU / {RAM_GIB:.0f} GiB RAM]"
os.makedirs(OUT, exist_ok=True)


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def load(path):
    with open(path) as fh:
        return [r for r in csv.DictReader(fh)]


def main(paths):
    files = []
    for p in paths:
        files.extend(sorted(glob.glob(p)))
    if not files:
        print("no CSV matched:", paths); sys.exit(1)
    rows = []
    for f in files:
        rows.extend(load(f))

    pts = []
    for r in rows:
        s = num(r.get("head_series")); rate = num(r.get("ingest_rate_per_s"))
        cpu = num(r.get("cpu_pct_of_ncores")); rss = num(r.get("rss_gib"))
        if None in (s, rate, cpu, rss):
            continue
        pts.append((s, rate, cpu, rss))
    pts.sort()
    if not pts:
        print("no usable rows"); sys.exit(1)
    S = [p[0] for p in pts]; R = [p[1] for p in pts]
    C = [p[2] for p in pts]; M = [p[3] for p in pts]

    peak_i = max(range(len(R)), key=lambda i: R[i])

    # ---- 1. ingest rate vs cardinality (headline) ----
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(S, [r/1e6 for r in R], "-o", color="#1f77b4", lw=2, label="sustained ingest rate")
    ax.scatter([S[peak_i]], [R[peak_i]/1e6], s=220, facecolors="none",
               edgecolors="red", linewidths=2, zorder=5)
    ax.annotate(f"peak {R[peak_i]/1e6:.2f} M/s\n@ {S[peak_i]/1e6:.1f}M series, {C[peak_i]:.0f}% CPU",
                (S[peak_i], R[peak_i]/1e6), textcoords="offset points", xytext=(12, 10),
                color="red", fontsize=10)
    ax.axhline(10, ls="--", color="0.5"); ax.text(S[0], 10.2, "10 M/s target", color="0.4", fontsize=9)
    ax.set_xscale("log")
    ax.set_xlabel("head series (cardinality)"); ax.set_ylabel("ingest rate (M samples/s)")
    ax.set_ylim(bottom=0)
    ax.set_title("Peak sustained ingest rate vs cardinality" + TITLE_SUFFIX)
    ax.grid(True, which="both", alpha=0.3); ax.legend()
    fig.tight_layout(); fig.savefig(f"{OUT}/ratemax_rate_vs_series.png", dpi=130)
    print(f"wrote {OUT}/ratemax_rate_vs_series.png")

    # ---- 2. CPU utilization vs cardinality ----
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(S, C, "-o", color="#d62728", lw=2)
    ax.axhline(100, ls="--", color="0.5"); ax.text(S[0], 96, "all cores", color="0.4", fontsize=9)
    ax.set_xscale("log"); ax.set_ylim(0, 110)
    ax.set_xlabel("head series (cardinality)"); ax.set_ylabel("CPU utilization (% of cores)")
    ax.set_title("Ingest CPU utilization vs cardinality" + TITLE_SUFFIX)
    ax.grid(True, which="both", alpha=0.3)
    fig.tight_layout(); fig.savefig(f"{OUT}/ratemax_cpu_vs_series.png", dpi=130)
    print(f"wrote {OUT}/ratemax_cpu_vs_series.png")

    # ---- 3. RSS vs cardinality, with RAM ceiling ----
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(S, M, "-o", color="#2ca02c", lw=2)
    ax.axhline(RAM_GIB, ls="--", color="red"); ax.text(S[0], RAM_GIB*0.96, f"{RAM_GIB:.0f} GiB total RAM", color="red", fontsize=9)
    ax.set_xscale("log"); ax.set_ylim(bottom=0)
    ax.set_xlabel("head series (cardinality)"); ax.set_ylabel("memory used — RSS (GiB)")
    ax.set_title("Memory used vs cardinality" + TITLE_SUFFIX)
    ax.grid(True, which="both", alpha=0.3)
    fig.tight_layout(); fig.savefig(f"{OUT}/ratemax_rss_vs_series.png", dpi=130)
    print(f"wrote {OUT}/ratemax_rss_vs_series.png")

    # ---- 4. 3D: the three dimensions we care about ----
    fig = plt.figure(figsize=(13, 10))
    ax = fig.add_subplot(111, projection="3d")
    ax.plot([r/1e6 for r in R], C, M, "-", color="0.6", lw=1)
    sc = ax.scatter([r/1e6 for r in R], C, M, c=[s/1e6 for s in S], cmap="plasma",
                    s=90, edgecolors="k", linewidths=0.4, depthshade=False)
    for r, c, m, s in zip(R, C, M, S):
        ax.text(r/1e6, c, m, f"  {s/1e6:.0f}M", fontsize=9, color="0.2")
    ax.set_xlabel("ingest rate (M samples/s)", labelpad=12)
    ax.set_ylabel("CPU utilization (% of cores)", labelpad=12)
    ax.set_zlabel("memory used — RSS (GiB)", labelpad=10)
    ax.set_title("Rate-max state space: ingest rate x CPU x memory (color = cardinality)" + TITLE_SUFFIX)
    ax.view_init(elev=18, azim=-60)
    cb = fig.colorbar(sc, ax=ax, shrink=0.6, pad=0.12); cb.set_label("head series (millions)")
    fig.tight_layout(); fig.savefig(f"{OUT}/ratemax_3d.png", dpi=130)
    print(f"wrote {OUT}/ratemax_3d.png")


if __name__ == "__main__":
    main(sys.argv[1:] or ["results/ratemax__*/ratemax.csv"])
