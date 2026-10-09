#!/usr/bin/env python3
"""Charts for SECURITY-RESULTS.md, from the CSVs in results/.

Same visual conventions as ../graphs/make_graphs.py and ../software/make_graphs.py:
white background, DejaVu Sans, 300 DPI, meant for pasting into the paper.

This is a single-cipher study, so the charts carry one series and no legend --
the title names what is plotted. Any second mark on a chart is a *reference*
(the ideal, or what sampling noise alone produces at this sample size), drawn
muted and dashed so it never reads as a second measurement. The series colour
and the two ramps were checked with validate_palette.py.

Usage: python3 make_graphs.py
"""

import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap, LogNorm

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")
OUT = os.path.join(HERE, "graphs")

# Paper-export mode. The standalone figures carry an explanatory footnote under
# each chart, which is right for a reader browsing graphs/ but duplicates the
# LaTeX \caption once the figure is placed in the manuscript. With --for-paper
# the footnotes are suppressed and the output goes to ../paper/images/, so the
# paper and the standalone figures stay in sync from one source.
FOR_PAPER = "--for-paper" in sys.argv
if FOR_PAPER:
    OUT = os.path.join(HERE, "..", "paper", "images")
    # Only the figure the manuscript actually includes. The SAC matrix is
    # reported there as a table instead, to stay inside the page limit.
    PAPER_NAMES = {
        "01_avalanche_rounds.png": "avalanche-rounds.png",
    }

NAME = "SipCon64"
PA, PB = 10, 6                       # round counts the construction uses

BLUE = "#2f6fab"     # the one series
AMBER = "#c07a1e"    # opposite pole of the diverging SAC ramp
MUTED = "#8a8a8a"
INK = "#222222"
WARN = "#c9352b"

# Diverging ramp for the SAC matrices: two hues, neutral grey midpoint, centred
# on the ideal p_ij = 1/2. Never a rainbow, never a hue at the middle.
SAC_CMAP = LinearSegmentedColormap.from_list("sac", [AMBER, "#efefee", BLUE])
# Sequential single hue, light -> dark, for the word-level magnitude grids.
SEQ_CMAP = LinearSegmentedColormap.from_list(
    "seq", ["#f4f7fa", BLUE, "#16314d"])

plt.rcParams.update({
    "figure.facecolor": "white",
    "axes.facecolor": "white",
    "savefig.facecolor": "white",
    "font.family": "DejaVu Sans",
    "font.size": 11,
    "axes.edgecolor": "#333333",
    "axes.labelcolor": INK,
    "text.color": "#111111",
    "xtick.color": "#333333",
    "ytick.color": "#333333",
    "grid.color": "#dddddd",
    "lines.linewidth": 2.0,
    "axes.spines.top": False,
    "axes.spines.right": False,
})

WORDS = ["$x_0$", "$x_1$", "$x_2$", "$x_3$"]


def save(fig, name):
    if FOR_PAPER:
        if name not in PAPER_NAMES:
            plt.close(fig)
            return
        name = PAPER_NAMES[name]
    fig.savefig(os.path.join(OUT, name), dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {'../paper/images' if FOR_PAPER else 'graphs'}/{name}")


def note(fig, *args, **kwargs):
    """Explanatory footnote under a chart -- omitted in paper-export mode,
    where the LaTeX caption says the same thing."""
    if not FOR_PAPER:
        fig.text(*args, **kwargs)


def chart_title(obj, *args, **kwargs):
    """Overall chart title -- omitted in paper-export mode for the same reason
    (IEEE figures are titled by their caption). Panel titles are kept: they
    label sub-plots, which a caption cannot do."""
    if not FOR_PAPER:
        obj.set_title(*args, **kwargs) if hasattr(obj, "set_title") \
            else obj.suptitle(*args, **kwargs)


def have(*names):
    return all(os.path.exists(os.path.join(RES, n)) for n in names)


def mark_rounds(ax, xs, ys, dy=(0, -18)):
    """Diamond + label at the round counts the construction actually uses."""
    for r, y in zip(xs, ys):
        ax.plot([r], [y], marker="D", ms=8, color=BLUE,
                markeredgecolor="white", markeredgewidth=1.5, zorder=6)
        ax.annotate(f"$p^{{{r}}}$", (r, y), textcoords="offset points",
                    xytext=dy, ha="center", fontsize=9.5, color=BLUE,
                    fontweight="bold")


# --------------------------------------------------------------------------
# 1. round-wise avalanche average -- the headline
# --------------------------------------------------------------------------
def fig_avalanche_rounds():
    if not have("avalanche_rounds.csv"):
        return
    d = pd.read_csv(os.path.join(RES, "avalanche_rounds.csv"))
    bits = int(d["state_bits"].iloc[0])

    fig, ax = plt.subplots(figsize=(7.4, 4.4))
    ax.axhline(50, color=MUTED, ls="--", lw=1.3, zorder=1)
    ax.text(11.9, 51.2, "ideal 50%", color=MUTED, fontsize=9, ha="right")
    ax.fill_between(d["round"], d["mean_pct"] - d["sd_pct"],
                    d["mean_pct"] + d["sd_pct"], color=BLUE, alpha=0.15, lw=0,
                    zorder=2)
    ax.plot(d["round"], d["mean_pct"], color=BLUE, marker="o", ms=5.5,
            zorder=3)

    ys = [float(d.loc[d["round"] == r, "mean_pct"].iloc[0]) for r in (PB, PA)]
    mark_rounds(ax, (PB, PA), ys)

    sat = int(d.loc[d["mean_pct"].sub(50).abs() < 0.05, "round"].min())
    ax.annotate(f"reaches 50% at {sat} rounds",
                xy=(sat, 49.0), xytext=(sat + 1.5, 33),
                arrowprops=dict(arrowstyle="->", color=INK, lw=1.1),
                fontsize=9.5, color=INK)

    ax.set_xlabel("rounds of the permutation")
    ax.set_ylabel("output bits changed (%)")
    chart_title(ax, f"{NAME}: round-wise avalanche, one input bit flipped",
                fontsize=12, pad=10)
    ax.set_xticks(range(1, 13))
    ax.set_xlim(0.6, 12.5)
    ax.set_ylim(0, 60)
    ax.grid(axis="y", lw=0.8)
    ax.set_axisbelow(True)
    note(fig, 0.5, -0.04,
             f"{bits}-bit state. Band is +/- 1 SD across samples; from the "
             "saturation round it matches a Binomial(b, 1/2) spread.",
             ha="center", fontsize=8.5, color=MUTED)
    save(fig, "01_avalanche_rounds.png")


# --------------------------------------------------------------------------
# 2. SAC deviation against what noise alone produces
# --------------------------------------------------------------------------
def fig_sac_deviation():
    if not have("sac_rounds.csv"):
        return
    d = pd.read_csv(os.path.join(RES, "sac_rounds.csv"))
    sd = float(d["noise_sd"].iloc[0])
    cells = float(d["cells"].iloc[0])

    fig, axes = plt.subplots(1, 2, figsize=(10.4, 4.2), sharey=True)
    for ax, col, title, ref, reflab in (
            (axes[0], "max_abs_dev", "Worst of all cells",
             sd * np.sqrt(2 * np.log(cells)), "expected max\nfrom noise"),
            (axes[1], "mean_abs_dev", "Mean over all cells",
             sd * np.sqrt(2 / np.pi), "expected mean\nfrom noise")):
        ax.semilogy(d["round"], d[col].clip(lower=1e-6), color=BLUE,
                    marker="o", ms=5.5, zorder=3)
        ax.axhline(ref, color=MUTED, ls=":", lw=1.4, zorder=2)
        ax.text(12.6, ref, reflab, color=MUTED, fontsize=8, va="center")
        ys = [float(d.loc[d["round"] == r, col].iloc[0]) for r in (PB, PA)]
        mark_rounds(ax, (PB, PA), ys, dy=(0, 10))
        ax.set_title(title, fontsize=11)
        ax.set_xlabel("rounds")
        ax.set_xticks(range(1, 13))
        ax.set_xlim(0.5, 14.8)
        ax.grid(axis="y", lw=0.8)
        ax.set_axisbelow(True)
    axes[0].set_ylabel(r"$|\,p_{ij} - 0.5\,|$")
    fig.suptitle(f"{NAME}: strict avalanche criterion, distance from the "
                 "ideal 1/2", fontsize=12.5, y=1.02)
    note(fig, 0.5, -0.13,
             "Dotted line is what this many samples produces by chance, and it "
             "differs between the panels: the expected\nmaximum over all cells "
             "on the left, the expected mean on the right. A curve sitting on "
             "it has no SAC\nbias this experiment can still resolve.",
             ha="center", fontsize=8.5, color=MUTED)
    save(fig, "02_sac_deviation.png")


# --------------------------------------------------------------------------
# 3. SAC matrices
# --------------------------------------------------------------------------
def fig_sac_heatmaps(rounds=(1, 2, 3, 4, 6, 10)):
    files = [f"sacmat_r{r}.u32" for r in rounds]
    if not have("sac_rounds.csv", *files):
        return
    d = pd.read_csv(os.path.join(RES, "sac_rounds.csv"))
    n = int(d["samples_per_cell"].iloc[0])
    bits = int(d["state_bits"].iloc[0])

    fig, axes = plt.subplots(2, 3, figsize=(10.5, 7.2))
    for ax, r, fn in zip(axes.ravel(), rounds, files):
        m = np.fromfile(os.path.join(RES, fn), dtype=np.uint32)
        m = m.reshape(bits, bits) / n
        im = ax.imshow(m, cmap=SAC_CMAP, vmin=0.0, vmax=1.0,
                       interpolation="nearest")
        used = "  (per data block)" if r == PB else (
            "  (init / final)" if r == PA else "")
        ax.set_title(f"$p^{{{r}}}${used}", fontsize=10.5,
                     fontweight="bold" if r in (PA, PB) else "normal")
        ax.set_xticks([0, 64, 128, 192])
        ax.set_yticks([0, 64, 128, 192])
        ax.tick_params(labelsize=7.5)
        for b in (64, 128, 192):   # word boundaries
            ax.axhline(b - 0.5, color="#ffffff", lw=0.6, alpha=0.75)
            ax.axvline(b - 0.5, color="#ffffff", lw=0.6, alpha=0.75)
    for ax in axes[1]:
        ax.set_xlabel("output bit $j$", fontsize=9)
    for ax in axes[:, 0]:
        ax.set_ylabel("input bit $i$", fontsize=9)
    cb = fig.colorbar(im, ax=axes, shrink=0.72, pad=0.02,
                      ticks=[0, 0.25, 0.5, 0.75, 1.0])
    cb.set_label(r"$p_{ij}$ = P(output bit $j$ flips | input bit $i$ flipped)",
                 fontsize=9)
    cb.ax.tick_params(labelsize=8)
    if not FOR_PAPER:
        fig.suptitle(f"{NAME}: SAC dependency matrix by round", fontsize=12.5)
    note(fig, 0.5, 0.03,
             "Neutral grey is the ideal 1/2; blue and amber are equal and "
             "opposite departures from it, so an all-grey\npanel is the "
             "target. White rules mark the 64-bit word boundaries. The "
             "diagonals at low rounds are\nSIPROUND's rotate-and-carry "
             "structure.",
             ha="center", fontsize=8.5, color=MUTED)
    save(fig, "03_sac_matrix.png")


# --------------------------------------------------------------------------
# 4. word-level diffusion -- only the panels that carry a finding
# --------------------------------------------------------------------------
def fig_word_diffusion():
    """Three panels, not eight.

    The full 2x4 grid of (reach, bias) x (p^1..p^4) was mostly dead space:
    reach is uniformly 100% at p^3 and p^4, and bias is saturated far above
    the colour scale at p^1..p^3. Only reach at p^1 and p^2, and bias at p^4,
    carry anything -- and bias at p^4 is where the x0 concentration shows. The
    remaining rounds are in results/diffusion_words.csv for anyone who wants
    them.
    """
    if not have("diffusion_words.csv", "sac_rounds.csv"):
        return
    d = pd.read_csv(os.path.join(RES, "diffusion_words.csv"))
    sacs = pd.read_csv(os.path.join(RES, "sac_rounds.csv"))
    sd = float(sacs["noise_sd"].iloc[0])
    floor = sd * np.sqrt(2 / np.pi)

    fig, axes = plt.subplots(1, 3, figsize=(10.8, 3.9))

    def grid(ax, g, fmt, cmap, **kw):
        im = ax.imshow(g, cmap=cmap, **kw)
        nrm = kw.get("norm")
        for i in range(4):
            for j in range(4):
                v = g[i, j]
                frac = nrm(v) if nrm is not None else \
                    (v - kw["vmin"]) / (kw["vmax"] - kw["vmin"])
                ax.text(j, i, fmt(v), ha="center", va="center", fontsize=9,
                        color="white" if frac > 0.55 else INK)
        ax.set_xticks(range(4)); ax.set_yticks(range(4))
        ax.set_xticklabels(WORDS, fontsize=9)
        ax.set_yticklabels(WORDS, fontsize=9)
        ax.set_xlabel("output word", fontsize=9)
        return im

    for ax, r in zip(axes[:2], (1, 2)):
        g = d[d["round"] == r].pivot(index="in_word", columns="out_word",
                                     values="completeness_pct").values
        im1 = grid(ax, g, lambda v: f"{v:.0f}", SEQ_CMAP, vmin=0, vmax=100)
        ax.set_title(f"reach after $p^{{{r}}}$", fontsize=11)
    axes[0].set_ylabel("input word", fontsize=9)
    fig.colorbar(im1, ax=axes[:2], shrink=0.85, pad=0.02, label="% connected")

    norm = LogNorm(vmin=1, vmax=4)
    g = d[d["round"] == 4].pivot(index="in_word", columns="out_word",
                                 values="mean_abs_dev").values / floor
    im2 = grid(axes[2], g, lambda v: f"{v:.1f}", SEQ_CMAP, norm=norm)
    axes[2].set_title("bias after $p^{4}$", fontsize=11)
    fig.colorbar(im2, ax=axes[2], shrink=0.85, pad=0.02,
                 label=r"$\times$ noise floor")

    fig.suptitle(f"{NAME}: diffusion between the four state words",
                 fontsize=12.5, y=1.04)
    note(fig, 0.5, -0.17,
         "$x_0$ is the rate, the only word an attacker writes to and reads "
         "from; $x_1$-$x_3$ are the capacity.\nReach is already complete "
         "everywhere by $p^3$, so later rounds are omitted. Bias at $p^4$ is "
         "the last round\nbefore saturation, and it sits on the paths into "
         "and out of $x_0$; 1.0 is indistinguishable from noise.",
         ha="center", fontsize=8.5, color=MUTED)
    save(fig, "04_word_diffusion.png")


# --------------------------------------------------------------------------
# 5. per-bit tag avalanche -- is any single input bit weak?
# --------------------------------------------------------------------------
def fig_aead_bitwise():
    """The class averages this replaces are in results/avalanche_aead.csv.

    A bar chart of those averages was dropped: seven of its eight bars read
    50.00, so it was a four-row table drawn as geometry. What an average
    cannot show is whether one individual input position is weak, which is
    what this plots.
    """
    if not have("avalanche_aead_bitwise.csv", "avalanche_aead.csv"):
        return
    cfg = pd.read_csv(os.path.join(RES, "avalanche_aead.csv"))
    nsamp = int(cfg["samples"].iloc[0])
    sd = 100.0 * np.sqrt(0.25 / (nsamp * 128))
    d = pd.read_csv(os.path.join(RES, "avalanche_aead_bitwise.csv"))

    classes = ["key", "nonce", "ad"]
    fig, axes = plt.subplots(1, 3, figsize=(12.2, 3.9), sharey=True)
    out = tot = 0
    for ax, cls in zip(axes, classes):
        ax.axhspan(50 - 3 * sd, 50 + 3 * sd, color=MUTED, alpha=0.14, lw=0,
                   zorder=0)
        sub = d[d["input_class"] == cls]
        ax.plot(sub["input_bit"], sub["tag_mean_pct"], lw=0, marker="o", ms=4,
                color=BLUE, alpha=0.9, zorder=3)
        ax.axhline(50, color=MUTED, ls="--", lw=1.3, zorder=2)
        ax.set_title(f"{cls} bits ({len(sub)})", fontsize=11)
        ax.set_xlabel(f"{cls} bit index")
        ax.grid(axis="y", lw=0.8)
        ax.set_axisbelow(True)
        out += int((sub["tag_mean_pct"].sub(50).abs() > 3 * sd).sum())
        tot += len(sub)
    axes[0].set_ylabel("tag bits changed (%)")
    axes[0].set_ylim(50 - 6 * sd, 50 + 6 * sd)
    axes[2].text(126, 50 + 3.4 * sd, r"$\pm 3\sigma$ sampling envelope",
                 fontsize=8.5, color=MUTED, ha="right")
    if not FOR_PAPER:
        fig.suptitle(f"{NAME}: tag avalanche per individual input bit",
                     fontsize=12.5, y=1.02)
    note(fig, 0.5, -0.1,
         "A weak key, nonce or AD position would show as a point far "
         f"outside the envelope; a class average hides it.\n{out} of {tot} "
         f"bits fall outside +/-3 sigma against {0.0027 * tot:.1f} "
         "expected by chance -- no weak position.",
         ha="center", fontsize=8.5, color=MUTED)
    save(fig, "05_aead_bitwise.png")


# --------------------------------------------------------------------------
# 6. randomness against round count
# --------------------------------------------------------------------------
def fig_sts_sweep():
    """One panel, not two.

    A second panel plotting the raw failure count was dropped: above the
    threshold it correlates with the round count at +0.115, i.e. it is
    sampling noise, and a panel that needs a caption telling the reader to
    ignore its main visual feature should not be a panel. The counts are in
    results/sts_sweep_summary.csv.
    """
    path = os.path.join(RES, "sts_sweep_summary.csv")
    if not os.path.exists(path):
        return
    d = pd.read_csv(path).copy()
    d["round"] = d["label"].str.lstrip("r").astype(int)
    d = d.sort_values("round")
    FLOOR = 1e-13

    fig, ax = plt.subplots(figsize=(7.4, 4.4))
    ax.axhspan(FLOOR / 3, 0.01, color=WARN, alpha=0.06, lw=0, zorder=0)
    ax.axhline(0.01, color=WARN, ls="--", lw=1.4, zorder=2)
    ax.text(12.3, 0.0035, r"reject below, $\alpha = 0.01$", color=WARN,
            fontsize=9, ha="right", va="top")
    ax.semilogy(d["round"], d["p_suite"].clip(lower=FLOOR), color=BLUE,
                marker="o", ms=5.5, zorder=3)
    off = d["p_suite"] <= FLOOR
    if off.any():
        ax.semilogy(d.loc[off, "round"], [FLOOR] * int(off.sum()),
                    linestyle="none", marker="v", ms=8, color=BLUE, zorder=4)
        ax.text(float(d.loc[off, "round"].max()) + 0.45, FLOOR * 1.9,
                "below the axis floor", fontsize=8.5, color=MUTED,
                va="bottom")
    ax.set_ylim(FLOOR / 3, 8)
    ax.set_ylabel("suite p-value")
    ys = [max(float(d.loc[d["round"] == r, "p_suite"].iloc[0]), FLOOR)
          for r in (PB, PA)]
    mark_rounds(ax, (PB, PA), ys, dy=(0, 11))

    first_pass = int(d.loc[d["verdict"] == "PASS", "round"].min())
    ax.axvspan(0.5, first_pass - 0.5, color=MUTED, alpha=0.1, lw=0, zorder=0)
    ax.set_xlabel("rounds of the permutation (counter mode)")
    ax.set_xticks(range(1, 13))
    ax.set_xlim(0.5, 12.5)
    ax.grid(axis="y", lw=0.8)
    ax.set_axisbelow(True)
    chart_title(ax, f"{NAME}: statistical randomness against round count",
                fontsize=12, pad=10)
    note(fig, 0.5, -0.11,
         f"Shaded columns are the rounds that fail. All ~190 SP 800-22 "
         f"sub-tests aggregate into this one statistic;\nthe permutation is "
         f"clean from {first_pass} rounds on.",
         ha="center", fontsize=8.5, color=MUTED)
    save(fig, "06_sts_round_sweep.png")


# --------------------------------------------------------------------------
# 7. the duplex staircase
# --------------------------------------------------------------------------
def fig_pt_staircase():
    if not have("avalanche_aead_bitwise.csv"):
        return
    d = pd.read_csv(os.path.join(RES, "avalanche_aead_bitwise.csv"))
    d = d[d["input_class"] == "plaintext"]

    fig, ax = plt.subplots(figsize=(7.4, 4.0))
    ax.axhline(50, color=MUTED, ls="--", lw=1.3)
    ax.text(4, 51, "50%", color=MUTED, fontsize=9)
    for b in range(64, 512, 64):      # rate-block boundaries
        ax.axvline(b, color=MUTED, lw=0.7, ls=":", alpha=0.7, zorder=0)
    ax.plot(d["input_bit"], d["c_mean_pct"], color=BLUE, lw=1.8, zorder=3)
    ax.annotate("step width = 64-bit rate block", xy=(192, 31.5),
                xytext=(243, 44),
                arrowprops=dict(arrowstyle="->", color=INK, lw=1.1),
                fontsize=9.5, color=INK)
    ax.set_xlabel("index of the flipped plaintext bit")
    ax.set_ylabel("ciphertext bits changed (%)")
    ax.set_title(f"{NAME}: ciphertext response to a plaintext bit flip",
                 fontsize=12, pad=10)
    ax.set_ylim(0, 56)
    ax.grid(axis="y", lw=0.8)
    ax.set_axisbelow(True)
    note(fig, 0.5, -0.13,
             "The staircase is the duplex mode, not a weakness: a flip in "
             "block j leaves blocks before j untouched,\nso a later bit moves "
             "less of the ciphertext. The tag, by contrast, is at 50% for "
             "every plaintext bit.",
             ha="center", fontsize=8.5, color=MUTED)
    save(fig, "07_plaintext_staircase.png")


def main():
    os.makedirs(OUT, exist_ok=True)
    print("charts ->")
    fig_avalanche_rounds()
    fig_sac_deviation()
    fig_sac_heatmaps()
    fig_word_diffusion()
    fig_aead_bitwise()
    fig_sts_sweep()
    fig_pt_staircase()


if __name__ == "__main__":
    main()
