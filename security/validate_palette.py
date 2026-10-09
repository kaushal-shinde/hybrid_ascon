#!/usr/bin/env python3
"""
Chart palette validator: colourblind and contrast checks for make_graphs.py.

Ported to Python because this machine has no node runtime, and the point of
such a check is that the colour decision is *computed* rather than eyeballed --
losing it to a missing runtime would mean guessing at colourblind separation.
Same OKLab conversion, same Machado CVD matrices, same thresholds.

Usage: python3 validate_palette.py "#2f6fab,#c07a1e" [--mode light|dark]
"""
import math
import sys

BAND = {"light": (0.43, 0.77), "dark": (0.48, 0.67)}   # OKLCH L
CHROMA_FLOOR = 0.10
CVD_TARGET, CVD_FLOOR = 8.0, 6.0    # OKLab dE*100, min(protan, deutan)
NORMAL_FLOOR = 15.0
CONTRAST_MIN = 3.0
DEFAULT_SURFACE = {"light": "#fcfcfb", "dark": "#1a1a19"}

MACHADO = {
    "protan": [[0.152286, 1.052583, -0.204868],
               [0.114503, 0.786281, 0.099216],
               [-0.003882, -0.048116, 1.051998]],
    "deutan": [[0.367322, 0.860646, -0.227968],
               [0.280085, 0.672501, 0.047413],
               [-0.011820, 0.042940, 0.968881]],
    "tritan": [[1.255528, -0.076749, -0.178779],
               [-0.078411, 0.930809, 0.147602],
               [0.004733, 0.691367, 0.303900]],
}


def hex2srgb(h):
    h = h.strip().lstrip("#")
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def s2lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lin(h):
    return [s2lin(c) for c in hex2srgb(h)]


def rel_lum(h):
    r, g, b = lin(h)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    hi, lo = sorted([rel_lum(a), rel_lum(b)], reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def oklab_from_lin(rgb):
    r, g, b = rgb
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return [0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s]


def oklch(h):
    L, a, b = oklab_from_lin(lin(h))
    return L, math.hypot(a, b)


def simulate(h, kind):
    r, g, b = lin(h)
    M = MACHADO[kind]
    return [min(1.0, max(0.0, M[i][0] * r + M[i][1] * g + M[i][2] * b))
            for i in range(3)]


def delta_e(h1, h2, kind=None):
    a = oklab_from_lin(simulate(h1, kind) if kind else lin(h1))
    b = oklab_from_lin(simulate(h2, kind) if kind else lin(h2))
    return 100 * math.dist(a, b)


def validate(palette, mode="light", surface=None, pairs="adjacent"):
    surface = surface or DEFAULT_SURFACE[mode]
    lo, hi = BAND[mode]
    report, ok = [], True

    off = [(c, round(oklch(c)[0], 3)) for c in palette
           if not (lo <= oklch(c)[0] <= hi)]
    report.append(("lightness band", "PASS" if not off else "FAIL",
                   f"all within [{lo}, {hi}]" if not off
                   else f"outside: {off}"))
    ok &= not off

    lowc = [(c, round(oklch(c)[1], 3)) for c in palette
            if oklch(c)[1] < CHROMA_FLOOR]
    report.append(("chroma floor", "PASS" if not lowc else "FAIL",
                   f"all >= {CHROMA_FLOOR}" if not lowc
                   else f"reads gray: {lowc}"))
    ok &= not lowc

    n = len(palette)
    pairlist = ([(i, j) for i in range(n) for j in range(i + 1, n)]
                if pairs == "all" else [(i, i + 1) for i in range(n - 1)])

    if pairlist:
        worst = min((min(delta_e(palette[i], palette[j], "protan"),
                         delta_e(palette[i], palette[j], "deutan")),
                     palette[i], palette[j]) for i, j in pairlist)
        state = ("PASS" if worst[0] >= CVD_TARGET
                 else "WARN" if worst[0] >= CVD_FLOOR else "FAIL")
        report.append((f"CVD separation ({pairs})", state,
                       f"worst dE={worst[0]:.1f} ({worst[1]} vs {worst[2]}), "
                       f"target >= {CVD_TARGET}"))
        ok &= state != "FAIL"

        nworst = min((delta_e(palette[i], palette[j]), palette[i], palette[j])
                     for i, j in pairlist)
        nstate = "PASS" if nworst[0] >= NORMAL_FLOOR else "FAIL"
        report.append(("normal-vision floor", nstate,
                       f"worst dE={nworst[0]:.1f} ({nworst[1]} vs "
                       f"{nworst[2]}), floor {NORMAL_FLOOR}"))
        ok &= nstate == "PASS"

        tri = min(delta_e(palette[i], palette[j], "tritan")
                  for i, j in pairlist)
        report.append(("tritan separation",
                       "PASS" if tri >= CVD_FLOOR else "WARN",
                       f"worst dE={tri:.1f}"))

    low = [(c, round(contrast(c, surface), 2)) for c in palette
           if contrast(c, surface) < CONTRAST_MIN]
    report.append((f"contrast vs {surface}", "PASS" if not low else "WARN",
                   f"all >= {CONTRAST_MIN}" if not low else f"low: {low}"))
    return report, ok


def main():
    args = sys.argv[1:]
    mode, pairs, colors = "light", "adjacent", None
    i = 0
    while i < len(args):
        if args[i] == "--mode":
            mode = args[i + 1]; i += 2
        elif args[i] == "--pairs":
            pairs = args[i + 1]; i += 2
        else:
            colors = args[i]; i += 1
    if not colors:
        print(__doc__)
        return 2
    palette = [c.strip() for c in colors.split(",") if c.strip()]
    report, ok = validate(palette, mode=mode, pairs=pairs)
    print(f"palette: {palette}   mode={mode}  pairs={pairs}")
    print("-" * 78)
    for name, state, detail in report:
        print(f"  {state:<5} {name:<28} {detail}")
    print("-" * 78)
    print("OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
