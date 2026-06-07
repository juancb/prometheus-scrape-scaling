#!/usr/bin/env python3
"""
Analyze a scale-cores experiment: peak sustained Prometheus ingest rate vs the
number of cores given to Prometheus, holding per-core cardinality constant.

Reads results/scale-cores__*/scale.csv (or $CSV), computes per-core-count
mean +/- 95% CI (Student-t, pure Python -- no scipy/numpy needed for stats),
writes a tidy scale-summary.csv, and renders plots with matplotlib.

Usage:
    CSV=results/scale-cores__v3.12.0__<ts>/scale.csv python3 scripts/analyze-scale.py
If CSV is unset, the most recent results/scale-cores__*/scale.csv is used.

Env:
    CSV       path to scale.csv (default: latest)
    OUT       plot output dir   (default: <csv dir>)
    TARGET    target ingest line, samples/s (default: 10_000_000)
"""
import csv
import glob
import math
import os
import statistics
import sys

# 95% two-sided Student-t critical values, df 1..30 (t_{0.975, df}); inf=1.960
_T975 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
    8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
    15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086,
    21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064, 25: 2.060, 26: 2.056,
    27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042,
}


def t975(df):
    if df <= 0:
        return float("nan")
    if df in _T975:
        return _T975[df]
    if df > 30:
        return 1.960  # large-sample normal approximation
    return _T975[max(_T975)]


def ci95(xs):
    """Return (mean, half_width_95ci, stdev, n)."""
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan"), float("nan"), 0
    m = statistics.fmean(xs)
    if n == 1:
        return m, float("nan"), 0.0, 1
    sd = statistics.stdev(xs)
    half = t975(n - 1) * sd / math.sqrt(n)
    return m, half, sd, n


def find_csv():
    if os.environ.get("CSV"):
        return os.environ["CSV"]
    cands = sorted(glob.glob("results/scale-cores__*/scale.csv"), key=os.path.getmtime)
    if not cands:
        sys.exit("no scale.csv found under results/scale-cores__*/ and $CSV unset")
    return cands[-1]


def main():
    csv_path = find_csv()
    out_dir = os.environ.get("OUT", os.path.dirname(csv_path))
    target = float(os.environ.get("TARGET", 10_000_000))
    os.makedirs(out_dir, exist_ok=True)

    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            if not r.get("ingest_rate_per_s") or r.get("event"):
                continue  # skip blank / event-tagged (OOM etc.) rows
            try:
                rows.append({
                    "cores": int(r["cores"]),
                    "total_series": int(r["total_series"]),
                    "rate": float(r["ingest_rate_per_s"]),
                    "cpu_pct": float(r["cpu_pct_of_ncores"]),
                    "rss": float(r["rss_gib"]),
                    "min_up": float(r["min_up"]),
                })
            except (ValueError, KeyError):
                continue

    if not rows:
        sys.exit(f"no usable data rows in {csv_path} yet")

    cores_list = sorted({r["cores"] for r in rows})
    summary = []
    for c in cores_list:
        grp = [r for r in rows if r["cores"] == c]
        rates = [r["rate"] for r in grp]
        m, half, sd, n = ci95(rates)
        cpu_m = statistics.fmean([r["cpu_pct"] for r in grp])
        rss_m = statistics.fmean([r["rss"] for r in grp])
        series = grp[0]["total_series"]
        summary.append({
            "cores": c, "total_series": series, "n": n,
            "mean_rate": m, "ci95_half": half, "stdev": sd,
            "rate_per_core": m / c, "cpu_pct": cpu_m, "rss_gib": rss_m,
        })

    # --- write tidy summary CSV -------------------------------------------
    sum_path = os.path.join(out_dir, "scale-summary.csv")
    with open(sum_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cores", "total_series", "replicates", "mean_rate_per_s",
                    "ci95_half_per_s", "stdev_per_s", "rate_per_core_per_s",
                    "mean_cpu_pct", "mean_rss_gib"])
        for s in summary:
            w.writerow([s["cores"], s["total_series"], s["n"],
                        f"{s['mean_rate']:.0f}", f"{s['ci95_half']:.0f}",
                        f"{s['stdev']:.0f}", f"{s['rate_per_core']:.0f}",
                        f"{s['cpu_pct']:.1f}", f"{s['rss_gib']:.2f}"])

    # --- console report ---------------------------------------------------
    print(f"# {csv_path}")
    print(f"{'cores':>5} {'series':>10} {'n':>2} {'mean M/s':>9} "
          f"{'+/-95% ':>8} {'M/s/core':>9} {'cpu%':>5} {'rss':>6}")
    for s in summary:
        half = "  n/a" if math.isnan(s["ci95_half"]) else f"{s['ci95_half']/1e6:6.3f}"
        print(f"{s['cores']:>5} {s['total_series']/1e6:9.1f}M {s['n']:>2} "
              f"{s['mean_rate']/1e6:8.3f} {half:>8} {s['rate_per_core']/1e6:8.3f} "
              f"{s['cpu_pct']:5.1f} {s['rss_gib']:5.1f}G")

    # extrapolated cores needed for target, using best per-core efficiency
    best = max(summary, key=lambda s: s["rate_per_core"])
    eff = best["rate_per_core"]
    print(f"\nPeak per-core efficiency: {eff/1e6:.3f} M/s/core (at {best['cores']} cores)")
    print(f"Linear extrapolation to {target/1e6:.0f}M/s: "
          f"{target/eff:.1f} cores at that efficiency")
    # does any measured point already cross target?
    crossed = [s for s in summary if s["mean_rate"] >= target]
    if crossed:
        c0 = min(crossed, key=lambda s: s["cores"])
        print(f"TARGET MET in measured data at {c0['cores']} cores "
              f"({c0['mean_rate']/1e6:.2f} M/s)")
    else:
        print(f"TARGET not reached within measured range "
              f"(max {summary[-1]['mean_rate']/1e6:.2f} M/s at {summary[-1]['cores']} cores)")

    render_plots(summary, out_dir, target)
    print(f"\nwrote {sum_path}")


def render_plots(summary, out_dir, target):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cores = [s["cores"] for s in summary]
    means = [s["mean_rate"] / 1e6 for s in summary]
    errs = [(0.0 if math.isnan(s["ci95_half"]) else s["ci95_half"] / 1e6) for s in summary]
    per_core = [s["rate_per_core"] / 1e6 for s in summary]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.2))

    # --- left: rate vs cores with 95% CI error bars + ideal-linear ref ----
    ax1.errorbar(cores, means, yerr=errs, fmt="o-", color="#1f77b4",
                 capsize=4, lw=2, ms=6, label="measured peak (mean ±95% CI)")
    # ideal linear scaling anchored at the first point
    c0, m0 = cores[0], means[0]
    ideal = [m0 / c0 * c for c in cores]
    ax1.plot(cores, ideal, "--", color="#888", lw=1.4,
             label=f"ideal linear ({m0/c0:.2f} M/s/core)")
    ax1.axhline(target / 1e6, color="#d62728", ls=":", lw=1.6,
                label=f"target {target/1e6:.0f} M/s")
    ax1.set_xlabel("Prometheus cores (GOMAXPROCS = taskset width)")
    ax1.set_ylabel("Peak sustained ingest (M samples/s)")
    ax1.set_title("Ingest scaling vs cores\n(per-core cardinality held constant: "
                  "400k series/core)")
    ax1.grid(True, alpha=0.3)
    ax1.legend(fontsize=9, loc="upper left")
    ax1.set_xticks(cores)

    # --- right: per-core efficiency (scaling quality) ---------------------
    ax2.plot(cores, per_core, "s-", color="#2ca02c", lw=2, ms=6)
    ax2.axhline(per_core[0], color="#888", ls="--", lw=1.4,
                label=f"single-point baseline ({per_core[0]:.2f})")
    ax2.set_xlabel("Prometheus cores")
    ax2.set_ylabel("Ingest per core (M samples/s/core)")
    ax2.set_title("Per-core efficiency\n(flat = perfect scaling; "
                  "decline = contention)")
    ax2.grid(True, alpha=0.3)
    ax2.legend(fontsize=9)
    ax2.set_xticks(cores)
    ax2.set_ylim(bottom=0)

    fig.suptitle("Prometheus 3.12.0 ingest scaling — AMD EPYC 7R32 (64 vCPU, 124 GiB)",
                 fontsize=12, y=1.02)
    fig.tight_layout()
    p1 = os.path.join(out_dir, "scale-rate-vs-cores.png")
    fig.savefig(p1, dpi=130, bbox_inches="tight")
    print(f"wrote {p1}")
    plt.close(fig)


if __name__ == "__main__":
    main()
