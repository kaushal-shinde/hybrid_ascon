#!/usr/bin/env python3
"""Generate report-style PNG charts from results.csv (software benchmarks).

Reads results.csv (in this same folder) and writes one PNG per chart, also
into this folder. Plain white background, standard fonts, 300 DPI.

Methodology: native x86_64 (no embedded cross-compiler on this machine),
GCC -O2, reference C from ../ascon-aead128, ../ascon-siphash and
../lwc-finalists. See notes.md in this folder for what each column means
and how it was measured.

Usage: python3 make_graphs.py
"""

import os
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "results.csv")
CURVE_CSV = os.path.join(HERE, "curve_results.csv")

ROM_C = "#5b3fa0"    # muted violet -- code/ROM-domain charts
SPEED_C = "#1a8a72"  # muted teal   -- speed-domain charts
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


def style_ax(ax):
    ax.grid(axis="x", linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.tick_params(length=0)


def hbar(df, filename, title, subtitle, color, key, unit, ascending=True,
         fmt="{:.0f}", logscale=False):
    d = df.sort_values(key, ascending=ascending).reset_index(drop=True)

    fig, ax = plt.subplots(figsize=(9, 5.4), dpi=300)
    y = range(len(d))
    ax.barh(list(y), d[key], color=color, height=0.6, edgecolor="none",
            alpha=0.92, zorder=3)

    for i, v in enumerate(d[key]):
        ax.text(v * (1.02 if not logscale else 1.06), i, fmt.format(v) + unit,
                va="center", ha="left", fontsize=10)

    ax.set_yticks(list(y))
    ax.set_yticklabels(d["design"], fontsize=10.5)

    if logscale:
        ax.set_xscale("log")
        ax.set_xlim(left=d[key].min() * 0.5)
    else:
        ax.set_xlim(left=0, right=d[key].max() * 1.2)
    ax.invert_yaxis()
    style_ax(ax)
    ax.set_xlabel(unit.strip() or None)

    fig.suptitle(title, fontsize=15, fontweight="bold", x=0.02, ha="left", y=0.99)
    ax.set_title(subtitle, fontsize=9.5, color="#555555", loc="left", pad=10)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(os.path.join(HERE, filename))
    plt.close(fig)
    print("wrote", filename)


def scatter(df):
    """Code size vs. throughput -- the software equivalent of the hardware
    report's area-vs-Fmax tradeoff chart."""
    fig, ax = plt.subplots(figsize=(9.5, 6.2), dpi=300)
    ax.scatter(df["rom_bytes"], df["throughput_MBps"], s=70,
               facecolor=ROM_C, edgecolor=ROM_C, alpha=0.85, zorder=3)

    # (dx in ROM bytes -- linear axis; y_mult multiplies throughput -- the
    # axis is log-scale, so a label offset there has to be multiplicative,
    # not additive, or it lands nowhere near the point it's labeling)
    offsets = {
        "Ascon-AEAD128": (250, 1.12, "left"),
        "hybrid r=128": (-200, 1.15, "right"),
        "hybrid r=64": (200, 0.82, "left"),
        "TinyJAMBU-128": (250, 1.18, "left"),
        "Xoodyak": (250, 0.80, "left"),
        "GIFT-COFB": (-200, 1.22, "right"),
        "Grain-128AEAD": (-200, 1.28, "right"),
        "SPARKLE": (250, 1.06, "left"),
        "Elephant (Dumbo)": (-200, 0.68, "right"),
        "ISAP (ISAP-A-128A)": (250, 1.10, "left"),
        "PHOTON-Beetle": (250, 1.35, "left"),
        "Romulus (Romulus-N)": (250, 1.06, "left"),
    }
    for _, r in df.iterrows():
        dx, ymult, ha = offsets.get(r["design"], (250, 1.1, "left"))
        ax.annotate(r["design"], (r["rom_bytes"] + dx, r["throughput_MBps"] * ymult),
                    ha=ha, va="center", fontsize=9.5, color="#222222")

    ax.set_yscale("log")
    ax.set_xlabel("ROM (.text, bytes, native x86_64 -O2)")
    ax.set_ylabel("throughput, MB/s (log scale)")
    ax.grid(linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.tick_params(length=0)
    ax.set_xlim(2500, 17500)
    ax.set_ylim(0.10, 550)

    fig.suptitle("Code size vs. throughput, native x86_64 reference C",
                 fontsize=15, fontweight="bold", x=0.02, ha="left", y=0.99)
    ax.set_title("Reference (unoptimized) C, not a hand-tuned software implementation -- see notes.md",
                 fontsize=9.5, color="#555555", loc="left", pad=10)

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(os.path.join(HERE, "01_rom_vs_throughput.png"))
    plt.close(fig)
    print("wrote 01_rom_vs_throughput.png")


# 12 hand-picked, maximally-separated hues (no two blues/greens/reds close
# enough to confuse at a glance -- an earlier version of this palette put
# TinyJAMBU/Elephant/Romulus in three near-identical steel-blues) -- based
# on Tableau's categorical palette, reordered for max adjacent contrast.
PALETTE = [
    "#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1", "#EDC948",
    "#76B7B2", "#FF9DA7", "#9C755F", "#5B3FA0", "#D37295", "#8A8A00",
]


def throughput_curve(curve_df):
    """cycles/byte vs. message size -- separates fixed per-call overhead
    from steady-state per-byte cost, the thing a single 4096B data point
    can't show (a design can look fast at 4096B and still be dominated by
    setup cost at protocol-packet sizes, or vice versa)."""
    fig, ax = plt.subplots(figsize=(9.5, 6.4), dpi=300)
    designs = curve_df["design"].unique()
    for i, name in enumerate(designs):
        d = curve_df[curve_df["design"] == name].sort_values("size_bytes")
        ax.plot(d["size_bytes"], d["cycles_per_byte"], marker="o", markersize=4,
                linewidth=1.6, color=PALETTE[i % len(PALETTE)], label=name, zorder=3)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("message size, bytes (log scale)")
    ax.set_ylabel("cycles / byte (log scale)")
    ax.grid(linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.tick_params(length=0)
    ax.legend(fontsize=8, ncol=2, loc="upper right", frameon=False)

    fig.suptitle("Throughput curve: fixed overhead vs. steady-state cost",
                 fontsize=15, fontweight="bold", x=0.02, ha="left", y=0.99)
    ax.set_title("encrypt-only, best-of-200 per point, 16/64/256/1024/4096B messages, 0B AD -- see notes.md",
                 fontsize=9.5, color="#555555", loc="left", pad=10)

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(os.path.join(HERE, "07_throughput_curve.png"))
    plt.close(fig)
    print("wrote 07_throughput_curve.png")


def encrypt_vs_decrypt(df):
    """Paired hbar: encrypt vs. decrypt cycles/byte, same 4096B measurement
    methodology both directions."""
    d = df.sort_values("cycles_per_byte", ascending=True).reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(9.5, 6.4), dpi=300)
    y = list(range(len(d)))
    h = 0.36
    ax.barh([v + h/2 for v in y], d["cycles_per_byte"], height=h,
            color=SPEED_C, alpha=0.92, zorder=3, label="encrypt")
    ax.barh([v - h/2 for v in y], d["dec_cycles_per_byte"], height=h,
            color="#c9622b", alpha=0.92, zorder=3, label="decrypt")

    ax.set_xscale("log")
    ax.set_yticks(y)
    ax.set_yticklabels(d["design"], fontsize=10)
    ax.invert_yaxis()
    ax.set_xlabel("cycles / byte (log scale)")
    ax.grid(axis="x", linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.tick_params(length=0)
    ax.legend(fontsize=10, loc="lower right", frameon=False)

    not_ok = d[d["dec_roundtrip_ok"] == 0]["design"].tolist()
    subtitle = "4096B message, 0B AD, native x86_64 -- see notes.md"
    if not_ok:
        subtitle += f" -- decrypt round-trip check FAILED for: {', '.join(not_ok)}"

    fig.suptitle("Encrypt vs. decrypt, cycles/byte",
                 fontsize=15, fontweight="bold", x=0.02, ha="left", y=0.99)
    ax.set_title(subtitle, fontsize=9.5, color="#555555", loc="left", pad=10)

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(os.path.join(HERE, "08_encrypt_vs_decrypt.png"))
    plt.close(fig)
    print("wrote 08_encrypt_vs_decrypt.png")


if __name__ == "__main__":
    df = pd.read_csv(CSV)

    scatter(df)
    hbar(df, "02_latency.png", "Latency",
         "cycles for one 16B AD / 16B message encrypt call, best-of-20000, native x86_64",
         SPEED_C, "latency_cycles", " cyc", ascending=True, fmt="{:.0f}")
    hbar(df, "03_throughput.png", "Throughput (log scale)",
         "4096B message, 0B AD, best-of-N timed run",
         SPEED_C, "throughput_MBps", " MB/s", ascending=False, fmt="{:.2f}", logscale=True)
    hbar(df, "04_rom.png", "ROM (code size)",
         "native x86_64 .text section, GCC -O2, reference C -- not embedded flash size",
         ROM_C, "rom_bytes", " B", ascending=True, fmt="{:.0f}")
    hbar(df, "05_ram.png", "RAM (static data)",
         "native x86_64 .data+.bss, GCC -O2 -- global/static state only, excludes the call stack",
         ROM_C, "ram_bytes", " B", ascending=True, fmt="{:.0f}")
    hbar(df, "06_stack.png", "Stack usage",
         "static worst-case call-chain depth from GCC -fstack-usage + call-graph analysis, see notes.md",
         ROM_C, "stack_bytes", " B", ascending=True, fmt="{:.0f}")

    if os.path.exists(CURVE_CSV):
        throughput_curve(pd.read_csv(CURVE_CSV))
    if "dec_cycles_per_byte" in df.columns:
        encrypt_vs_decrypt(df)

    print("done")
