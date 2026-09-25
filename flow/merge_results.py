#!/usr/bin/env python3
"""Merge the Vivado and sky130 sweeps into graphs/results.csv.

Reads the two per-sweep CSVs produced by run_vivado.sh / run_sky130.sh and
writes the combined table the charts and RESULTS.md are built from.

FPGA power is total on-chip (dynamic + 57 mW device static), matching the
metric the previous edition reported. Power is vectorless on both sides for all
eleven designs -- the activity
stimulus used for the original Ascon-family SAIF/VCD annotation was not kept,
so both *_power_measured columns are "no" throughout. That is a downgrade in
accuracy for those two designs and an upgrade in consistency for the table as
a whole; see RESULTS.md.

Usage: python3 merge_results.py [--vivado F] [--sky130 F] [--out F]
"""
import argparse, csv, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# module name -> the friendly name used throughout the reports
NAMES = [
    ("ascon_aead128",    "Ascon-AEAD128"),
    ("sipcon64_aead",  "SipCon64"),
    ("tinyjambu_lwc",    "tinyjambu"),
    ("xoodyak_lwc",      "xoodyak"),
    ("giftcofb_lwc",     "giftcofb"),
    ("grain128aead_lwc", "grain128aead"),
    ("sparkle_lwc",      "sparkle"),
    ("elephant_lwc",     "elephant"),
    ("isap_lwc",         "isap"),
    ("photonbeetle_lwc", "photonbeetle"),
    ("romulus_n_lwc",    "romulus"),
]

COLS = ["design", "verified", "fpga_lut", "fpga_reg", "fpga_fmax_mhz",
        "fpga_power_mw", "fpga_power_measured", "sky130_area_um2",
        "sky130_ge", "sky130_fmax_mhz", "sky130_power_mw",
        "sky130_power_measured"]

SKY_COLS = ["design", "period_ns", "fmax_mhz", "area_um2", "gate_equiv",
            "power_mw", "clock_skew_ns"]


def load_vivado(path):
    if not os.path.exists(path):
        sys.exit(f"missing {path} -- run run_vivado.sh first")
    return {r["design"]: r for r in csv.DictReader(open(path))}


def load_sky130(path):
    if not os.path.exists(path):
        sys.exit(f"missing {path} -- run run_sky130.sh first")
    rows = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("design,"):
                continue
            rows[line.split(",")[0]] = dict(zip(SKY_COLS, line.split(",")))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vivado", default=os.path.join(HERE, "vivado_results.csv"))
    ap.add_argument("--sky130", default=os.path.join(HERE, "sky130_results.csv"))
    ap.add_argument("--out",    default=os.path.join(ROOT, "graphs", "results.csv"))
    a = ap.parse_args()

    V, S = load_vivado(a.vivado), load_sky130(a.sky130)
    missing = [m for m, _ in NAMES if m not in V or m not in S]
    if missing:
        sys.exit("incomplete sweeps, missing: " + ", ".join(missing))

    with open(a.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(COLS)
        for mod, friendly in NAMES:
            v, s = V[mod], S[mod]
            w.writerow([
                friendly, "yes",
                v["luts"], v["regs"], f'{float(v["fmax_mhz"]):.2f}',
                f'{float(v["total_power_mw"]):.1f}', "no",
                f'{float(s["area_um2"]):.0f}', s["gate_equiv"],
                f'{float(s["fmax_mhz"]):.1f}',
                f'{float(s["power_mw"]):.3f}', "no",
            ])
    print(f"wrote {a.out} ({len(NAMES)} designs)")


if __name__ == "__main__":
    main()
