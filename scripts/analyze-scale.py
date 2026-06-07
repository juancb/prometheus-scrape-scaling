#!/usr/bin/env python3
"""
Analyze a scale-cores experiment: peak sustained Prometheus ingest rate vs the
number of cores given to Prometheus, holding per-core cardinality constant.

Reads results/scale-cores__*/scale.csv (or $CSV), computes per-core-count
statistics (mean +/- 95% CI, Student-t, pure Python -- no scipy/numpy needed
for stats), and -- crucially -- separates CPU-SATURATED replicates from
under-saturated ones. The closed-loop interval controller does not always drive
the box to saturation at high core counts (many simultaneous targets make scrape
duration noisy, so the controller backs off to a loose interval). A replicate
that peaked below SAT_CPU% CPU is a *lower bound* on capacity, not the peak, and
is reported as such rather than averaged in as if it were the ceiling.

Writes a tidy scale-summary.csv and renders plots with matplotlib.

Env:
    CSV       path to scale.csv (default: most recent)
    OUT       plot output dir   (default: <csv dir>)
    TARGET    target ingest line, samples/s (default: 10_000_000)
    SAT_CPU   CPU% of N cores at/above which a replicate counts as saturated
              (default: 85)
"""
import csv
import glob
import math
import os
import statistics
import sys

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
    return 1.960 if df > 30 else _T975[max(_T975)]


def ci95(xs):
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan"), float("nan"), 0
    m = statistics.fmean(xs)
    if n == 1:
        return m, float("nan"), 0.0, 1
    sd = statistics.stdev(xs)
    return m, t975(n - 1) * sd / math.sqrt(n), sd, n


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
    sat_cpu = float(os.environ.get("SAT_CPU", 85))
    os.makedirs(out_dir, exist_ok=True)

    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            if not r.get("ingest_rate_per_s") or r.get("event"):
                continue
            try:
                rows.append({
                    "cores": int(r["cores"]),
                    "total_series": int(r["total_series"]),
                    "rate": float(r["ingest_rate_per_s"]),
                    "cpu_pct": float(r["cpu_pct_of_ncores"]),
                    "rss": float(r["rss_gib"]),
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
        sat = [r for r in grp if r["cpu_pct"] >= sat_cpu]
        m, half, sd, n = ci95(rates)
        sat_rates = [r["rate"] for r in sat]
        sm_, shalf, ssd, sn = ci95(sat_rates) if sat_rates else (float("nan"),) * 4
        # capacity estimate: mean of saturated reps if we have >=2; else the max
        # observed rate (a lower bound on the true saturated ceiling).
        if sn >= 2:
            cap, cap_kind = sm_, "measured"
        elif sn == 1:
            cap, cap_kind = sat_rates[0], "measured(n=1)"
        else:
            cap, cap_kind = max(rates), "lower-bound"
        summary.append({
            "cores": c, "total_series": grp[0]["total_series"], "n": n,
            "mean_rate": m, "ci95_half": half, "stdev": sd,
            "n_sat": sn, "sat_mean": sm_, "sat_ci95": shalf,
            "max_rate": max(rates), "mean_cpu": statistics.fmean([x["cpu_pct"] for x in grp]),
            "max_cpu": max(x["cpu_pct"] for x in grp),
            "rss": statistics.fmean([x["rss"] for x in grp]),
            "cap": cap, "cap_kind": cap_kind,
            "cap_per_core": cap / c,
        })

    sum_path = os.path.join(out_dir, "scale-summary.csv")
    with open(sum_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cores", "total_series", "replicates", "n_saturated",
                    "capacity_per_s", "capacity_kind", "capacity_per_core_per_s",
                    "all_mean_rate_per_s", "all_ci95_half_per_s",
                    "sat_mean_rate_per_s", "sat_ci95_half_per_s",
                    "max_rate_per_s", "mean_cpu_pct", "max_cpu_pct", "mean_rss_gib"])
        for s in summary:
            def f0(x): return "" if (isinstance(x, float) and math.isnan(x)) else f"{x:.0f}"
            w.writerow([s["cores"], s["total_series"], s["n"], s["n_sat"],
                        f0(s["cap"]), s["cap_kind"], f0(s["cap_per_core"]),
                        f0(s["mean_rate"]), f0(s["ci95_half"]),
                        f0(s["sat_mean"]), f0(s["sat_ci95"]), f0(s["max_rate"]),
                        f"{s['mean_cpu']:.1f}", f"{s['max_cpu']:.1f}", f"{s['rss']:.2f}"])

    # console report
    print(f"# {csv_path}    (saturation threshold: CPU >= {sat_cpu:.0f}% of N cores)")
    print(f"{'cores':>5} {'series':>8} {'sat/n':>6} {'capacity':>9} {'kind':>13} "
          f"{'M/s/core':>9} {'meanCPU':>7} {'maxCPU':>6} {'rss':>6}")
    for s in summary:
        print(f"{s['cores']:>5} {s['total_series']/1e6:7.1f}M {s['n_sat']:>2}/{s['n']:<3} "
              f"{s['cap']/1e6:8.2f} {s['cap_kind']:>13} {s['cap_per_core']/1e6:8.3f} "
              f"{s['mean_cpu']:6.1f}% {s['max_cpu']:5.1f}% {s['rss']:5.1f}G")

    clean = [s for s in summary if s["cap_kind"].startswith("measured")]
    print("\n-- findings --")
    crossed = [s for s in clean if s["cap"] >= target]
    if crossed:
        c0 = min(crossed, key=lambda s: s["cores"])
        print(f"* {target/1e6:.0f} M/s target: MET at {c0['cores']} saturated cores "
              f"({c0['cap']/1e6:.2f} M/s, {c0['n_sat']}/{c0['n']} reps saturated, "
              f"CPU {c0['mean_cpu']:.0f}%)")
    if clean:
        best_eff = max(clean, key=lambda s: s["cap_per_core"])
        worst_eff = min(clean, key=lambda s: s["cap_per_core"])
        print(f"* per-core efficiency: {best_eff['cap_per_core']/1e6:.3f} M/s/core "
              f"@ {best_eff['cores']}c -> {worst_eff['cap_per_core']/1e6:.3f} "
              f"@ {worst_eff['cores']}c "
              f"({100*worst_eff['cap_per_core']/best_eff['cap_per_core']:.0f}% of peak)")
    undersat = [s for s in summary if s["cap_kind"] == "lower-bound"]
    if undersat:
        cc = ", ".join(f"{s['cores']}c" for s in undersat)
        print(f"* under-saturated (controller never reached {sat_cpu:.0f}% CPU; "
              f"capacity is a LOWER BOUND): {cc}")
    spot = [s for s in summary if s["cap_kind"] == "measured(n=1)"]
    if spot:
        cc = ", ".join(f"{s['cores']}c={s['cap']/1e6:.1f}M/s" for s in spot)
        print(f"* single saturated replicate (wide uncertainty): {cc}")

    render_plots(summary, out_dir, target, sat_cpu)
    print(f"\nwrote {sum_path}")


def render_plots(summary, out_dir, target, sat_cpu):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cores = [s["cores"] for s in summary]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13.5, 5.4))

    # ---- left: capacity vs cores, saturated vs lower-bound distinguished ----
    sat_c, sat_y, sat_e = [], [], []
    lb_c, lb_y = [], []
    for s in summary:
        if s["cap_kind"].startswith("measured"):
            sat_c.append(s["cores"]); sat_y.append(s["cap"] / 1e6)
            sat_e.append(0.0 if math.isnan(s["sat_ci95"]) else s["sat_ci95"] / 1e6)
        else:
            lb_c.append(s["cores"]); lb_y.append(s["cap"] / 1e6)
    if sat_c:
        ax1.errorbar(sat_c, sat_y, yerr=sat_e, fmt="o-", color="#1f77b4", capsize=4,
                     lw=2, ms=7, label="saturated peak (mean ±95% CI)", zorder=3)
    if lb_c:
        ax1.scatter(lb_c, lb_y, marker="v", s=70, facecolors="none",
                    edgecolors="#d62728", lw=1.8, zorder=3,
                    label="under-saturated (lower bound)")
    # ideal-linear reference anchored at the smallest (cleanly saturated) point
    anchor = next(s for s in summary if s["cap_kind"].startswith("measured"))
    eff0 = anchor["cap"] / anchor["cores"]
    ax1.plot(cores, [eff0 * c / 1e6 for c in cores], "--", color="#999", lw=1.4,
             label=f"ideal linear ({eff0/1e6:.2f} M/s/core @ {anchor['cores']}c)")
    ax1.axhline(target / 1e6, color="#2ca02c", ls=":", lw=1.8,
                label=f"target {target/1e6:.0f} M/s")
    ax1.set_xlabel("Prometheus cores (GOMAXPROCS = taskset width)")
    ax1.set_ylabel("Peak sustained ingest (M samples/s)")
    ax1.set_title("Ingest capacity vs cores\n(per-core cardinality fixed at 400k series/core)")
    ax1.grid(True, alpha=0.3); ax1.legend(fontsize=8.5, loc="upper left")
    ax1.set_xticks(cores); ax1.set_ylim(bottom=0)

    # ---- right: per-core efficiency over the cleanly-saturated regime ----
    ce = [s for s in summary if s["cap_kind"].startswith("measured")]
    ax2.plot([s["cores"] for s in ce], [s["cap_per_core"] / 1e6 for s in ce],
             "s-", color="#1f77b4", lw=2, ms=7, label="measured")
    ax2.axhline(ce[0]["cap_per_core"] / 1e6, color="#999", ls="--", lw=1.4,
                label=f"baseline {ce[0]['cap_per_core']/1e6:.2f} M/s/core @ {ce[0]['cores']}c")
    # plot lower-bound efficiency too, hollow
    cb = [s for s in summary if s["cap_kind"] == "lower-bound"]
    if cb:
        ax2.scatter([s["cores"] for s in cb], [s["cap_per_core"] / 1e6 for s in cb],
                    marker="v", s=70, facecolors="none", edgecolors="#d62728",
                    lw=1.8, label="lower bound")
    ax2.set_xlabel("Prometheus cores")
    ax2.set_ylabel("Ingest per core (M samples/s/core)")
    ax2.set_title("Per-core efficiency\n(flat = perfect scaling; decline = contention)")
    ax2.grid(True, alpha=0.3); ax2.legend(fontsize=8.5)
    ax2.set_xticks(cores); ax2.set_ylim(bottom=0)

    fig.suptitle("Prometheus 3.12.0 ingest scaling — AMD EPYC 7R32 (64 vCPU, 124 GiB, tmpfs TSDB)",
                 fontsize=12, y=1.02)
    fig.tight_layout()
    p1 = os.path.join(out_dir, "scale-rate-vs-cores.png")
    fig.savefig(p1, dpi=130, bbox_inches="tight")
    print(f"wrote {p1}")
    plt.close(fig)


if __name__ == "__main__":
    main()
