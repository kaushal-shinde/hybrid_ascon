#!/usr/bin/env python3
"""Generate report-style PNG charts from results.csv.

Reads results.csv (in this same folder) and writes one PNG per chart, also
into this folder. Plain white background, standard fonts, 300 DPI — meant
for pasting into a document or report, not a dashboard.

Usage: python3 make_graphs.py
"""

import os
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from matplotlib.lines import Line2D

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "results.csv")

FPGA = "#2f6fab"    # muted blue  — FPGA-domain charts
ASIC = "#c07a1e"    # muted amber — sky130-domain charts
VERIFIED = "#2f7d32"  # muted green — verified marker/label color
MUTED = "#8a8a8a"

plt.rcParams.update({
    "figure.facecolor": "white",
    "axes.facecolor": "white",
    "savefig.facecolor": "white",
    "font.family": "DejaVu Sans",
    "font.size": 11,
    "axes.edgecolor": "#333333",
    "axes.labelcolor": "#222222",
    "text.color": "#111111",
    "xtick.color": "#333333",
    "ytick.color": "#333333",
    "grid.color": "#dddddd",
})


def load():
    df = pd.read_csv(CSV)
    df["verified"] = df["verified"].map({"yes": True, "no": False})
    df["fpga_power_measured"] = df["fpga_power_measured"].map({"yes": True, "no": False})
    df["sky130_power_measured"] = df["sky130_power_measured"].map({"yes": True, "no": False})
    return df


def style_ax(ax):
    ax.grid(axis="x", linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.tick_params(length=0)


def hbar(df, filename, title, subtitle, color, key, unit, ascending=False, fmt="{:.0f}",
         logscale=False, faint_key=None, faint_label=("measured", "vectorless estimate")):
    """One sorted horizontal-bar chart. Verified cores get a bold y-label;
    faint_key dims bars whose value is a vectorless estimate rather than a
    simulation-measured one."""
    d = df.sort_values(key, ascending=ascending).reset_index(drop=True)

    fig, ax = plt.subplots(figsize=(9, 5.4), dpi=300)
    y = range(len(d))
    alphas = [0.4 if faint_key and not row[faint_key] else 0.95 for _, row in d.iterrows()]
    bars = ax.barh(list(y), d[key], color=color, height=0.6, edgecolor="none", zorder=3)
    for b, a in zip(bars, alphas):
        b.set_alpha(a)

    for i, v in enumerate(d[key]):
        ax.text(v * (1.02 if not logscale else 1.06), i, fmt.format(v) + unit,
                va="center", ha="left", fontsize=10)

    ax.set_yticks(list(y))
    ax.set_yticklabels(d["design"], fontsize=10.5)
    for tick, ok in zip(ax.get_yticklabels(), d["verified"]):
        if ok:
            tick.set_fontweight("bold")
            tick.set_color(VERIFIED)

    if logscale:
        ax.set_xscale("log")
        ax.set_xlim(left=d[key].min() * 0.5)
    else:
        ax.set_xlim(left=0, right=d[key].max() * 1.18)
    ax.invert_yaxis()
    style_ax(ax)
    ax.set_xlabel(unit.strip() or None)

    fig.suptitle(title, fontsize=15, fontweight="bold", x=0.02, ha="left", y=0.99)
    ax.set_title(subtitle, fontsize=9.5, color="#555555", loc="left", pad=10)

    handles = [Patch(facecolor=color, edgecolor="none", alpha=0.95, label="value")]
    if faint_key:
        handles = [
            Patch(facecolor=color, edgecolor="none", alpha=0.95, label=faint_label[0]),
            Patch(facecolor=color, edgecolor="none", alpha=0.4, label=faint_label[1]),
        ]
    loc = "upper right" if ascending else "lower right"
    ax.legend(handles=handles, loc=loc, frameon=False, fontsize=8.5)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(os.path.join(HERE, filename))
    plt.close(fig)
    print("wrote", filename)


def scatter(df):
    """sky130 area vs. sky130 Fmax, one point per core."""
    fig, ax = plt.subplots(figsize=(9.5, 6.2), dpi=300)
    for _, r in df.iterrows():
        face = VERIFIED if r["verified"] else "none"
        ax.scatter(r["sky130_area_um2"], r["sky130_fmax_mhz"], s=70,
                   facecolor=face, edgecolor=(VERIFIED if r["verified"] else MUTED),
                   linewidth=1.6, zorder=3)

    offsets = {
        "Ascon-AEAD128": (0, 11, "center"),
        "tinyjambu": (2200, -3, "left"),
        "grain128aead": (0, -15, "center"),
        "xoodyak": (0, 11, "center"),
        "giftcofb": (0, -15, "center"),
        "romulus": (0, 11, "center"),
        "isap": (0, -15, "center"),
        "photonbeetle": (0, -15, "center"),
        "sparkle": (0, -15, "center"),
        "elephant": (-2200, 3, "right"),
        "hybrid r=64": (-1800, 9, "right"),
    }
    for _, r in df.iterrows():
        dx, dy, ha = offsets.get(r["design"], (0, 11, "center"))
        ax.annotate(r["design"], (r["sky130_area_um2"] + dx, r["sky130_fmax_mhz"] + dy),
                    ha=ha, va="center", fontsize=9.5,
                    color=(VERIFIED if r["verified"] else "#333333"),
                    fontweight=("bold" if r["verified"] else "normal"))

    ax.set_xlabel("sky130 cell area (µm²)")
    ax.set_ylabel("sky130 Fmax (MHz)")
    ax.grid(linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.tick_params(length=0)
    ax.set_xlim(10000, 182000)
    ax.set_ylim(15, 280)

    fig.suptitle("Area vs. speed, sky130 — all eleven cores", fontsize=15, fontweight="bold",
                 x=0.02, ha="left", y=0.99)
    ax.set_title("Filled = functionally verified (xsim or KAT).  Open ring = lint-clean only, unverified.",
                 fontsize=9.5, color="#555555", loc="left", pad=10)

    handles = [
        Line2D([0], [0], marker="o", color="none", markerfacecolor=VERIFIED,
               markeredgecolor=VERIFIED, markersize=8, label="verified"),
        Line2D([0], [0], marker="o", color="none", markerfacecolor="none",
               markeredgecolor=MUTED, markersize=8, markeredgewidth=1.6, label="unverified"),
    ]
    ax.legend(handles=handles, loc="upper right", frameon=False, fontsize=9)

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(os.path.join(HERE, "01_area_vs_fmax_sky130.png"))
    plt.close(fig)
    print("wrote 01_area_vs_fmax_sky130.png")


if __name__ == "__main__":
    df = load()

    scatter(df)
    hbar(df, "02_fpga_fmax.png", "FPGA Fmax",
         "Xilinx Artix-7 xc7a12ticsg325-1L, out-of-context, post-route — higher is better",
         FPGA, "fpga_fmax_mhz", " MHz", ascending=False, fmt="{:.1f}")
    hbar(df, "03_fpga_luts.png", "FPGA logic (Slice LUTs)",
         "Xilinx Artix-7 xc7a12ticsg325-1L — lower is better",
         FPGA, "fpga_lut", "", ascending=True, fmt="{:.0f}")
    hbar(df, "04_fpga_power.png", "FPGA on-chip power",
         "Vivado report_power — lower is better",
         FPGA, "fpga_power_mw", " mW", ascending=True, fmt="{:.1f}", faint_key="fpga_power_measured",
         faint_label=("SAIF, period-matched", "vectorless estimate"))
    hbar(df, "05_sky130_fmax.png", "sky130 Fmax",
         "SkyWater 130nm, OpenROAD — 9 finalists are single-point floors, not searched ceilings",
         ASIC, "sky130_fmax_mhz", " MHz", ascending=False, fmt="{:.1f}")
    hbar(df, "06_sky130_area.png", "sky130 cell area",
         "SkyWater 130nm, OpenROAD post-P&R — lower is better",
         ASIC, "sky130_area_um2", " µm²", ascending=True, fmt="{:.0f}")
    hbar(df, "07_sky130_power.png", "sky130 power (log scale)",
         "OpenROAD report_power — sparkle is a likely vectorless artifact, see RESULTS.md",
         ASIC, "sky130_power_mw", " mW", ascending=True, fmt="{:.2f}", logscale=True,
         faint_key="sky130_power_measured", faint_label=("VCD-annotated", "vectorless estimate"))

    print("done")
