#!/usr/bin/env python3
"""Rebuild flow/vivado_results.csv from the Vivado reports already on disk.

Exists because the sweep originally recorded a count of LUT *primitives*
(get_cells PRIMITIVE_GROUP == LUT) where the conventional FPGA area metric --
and the one published figures use -- is "Slice LUTs" from report_utilization.
The two differ by up to 39%, because Vivado packs two logic functions into one
dual-output LUT6. vivado_flow.tcl now reads Slice LUTs directly; this script
re-derives the same value for sweeps that ran before that fix, so they do not
have to be repeated.

Also pulls occupied slices and logic levels, which RESULTS.md 3.1/3.2 report
and the CSV did not previously carry.

Usage: python3 reextract_vivado.py [--work DIR] [--out F]
"""
import argparse, csv, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGNS = ["ascon_aead128", "sipcon64_aead", "tinyjambu_lwc", "xoodyak_lwc",
           "giftcofb_lwc", "grain128aead_lwc", "sparkle_lwc", "elephant_lwc",
           "isap_lwc", "photonbeetle_lwc", "romulus_n_lwc"]


def util_row(path, label):
    """First '| <label> | <n> |' value in a report_utilization table."""
    pat = re.compile(r"^\|\s*" + re.escape(label) + r"\s*\|\s*(\d+)")
    with open(path) as fh:
        for line in fh:
            m = pat.match(line)
            if m:
                return int(m.group(1))
    return None


def power_bits(path):
    """(total on-chip, dynamic, device static) in mW from report_power."""
    vals = {}
    with open(path) as fh:
        for line in fh:
            for key, label in (("total", r"Total On-Chip Power \(W\)"),
                               ("dyn",   r"Dynamic \(W\)"),
                               ("stat",  r"Device Static \(W\)")):
                m = re.search(r"\|\s*" + label + r"\s*\|\s*([0-9.]+)", line)
                if m:
                    vals[key] = float(m.group(1)) * 1000.0
    return vals.get("total"), vals.get("dyn"), vals.get("stat")


def timing_bits(path):
    """Worst setup slack (ns) and the logic-level count of that path."""
    wns = levels = None
    with open(path) as fh:
        for line in fh:
            if wns is None:
                m = re.search(r"Slack \(MET\) :\s*([-0-9.]+)ns", line)
                if m:
                    wns = float(m.group(1))
            if levels is None:
                m = re.search(r"Logic Levels:\s*(\d+)", line)
                if m:
                    levels = int(m.group(1))
            if wns is not None and levels is not None:
                break
    return wns, levels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.expanduser("~/.ascon-flow/vivado/out"))
    ap.add_argument("--out",  default=os.path.join(HERE, "vivado_results.csv"))
    a = ap.parse_args()

    out = []
    for d in DESIGNS:
        res = os.path.join(a.work, d, f"{d}_result.csv")
        if not os.path.exists(res):
            print(f"  skip {d}: no result.csv")
            continue
        r = list(csv.DictReader(open(res)))[0]
        per = r["period_ns"]
        util = os.path.join(a.work, d, f"{d}_{per}_util.txt")
        tim = os.path.join(a.work, d, f"{d}_{per}_timing.txt")
        luts = util_row(util, "Slice LUTs") if os.path.exists(util) else None
        regs = util_row(util, "Slice Registers") if os.path.exists(util) else None
        slices = util_row(util, "Slice") if os.path.exists(util) else None
        wns, levels = timing_bits(tim) if os.path.exists(tim) else (None, None)
        pwr = os.path.join(a.work, d, f"{d}_{per}_power.txt")
        ptot, pdyn, pstat = power_bits(pwr) if os.path.exists(pwr) else (None, None, None)
        if luts is None:
            print(f"  WARN {d}: no Slice LUTs in {util}; keeping cell count")
            luts = r["luts"]
        out.append({
            "design": d, "period_ns": per, "fmax_mhz": r["fmax_mhz"],
            "luts": luts, "regs": regs if regs is not None else r["regs"],
            "occupied_slices": slices if slices is not None else "",
            "logic_levels": levels if levels is not None else "",
            "wns_ns": f"{wns:+.3f}" if wns is not None else "",
            "unrouted": r["unrouted"],
            "dyn_power_mw": f"{pdyn:.1f}" if pdyn is not None else r["dyn_power_mw"],
            "static_power_mw": f"{pstat:.1f}" if pstat is not None else "",
            "total_power_mw": f"{ptot:.1f}" if ptot is not None else "",
        })

    cols = ["design", "period_ns", "fmax_mhz", "luts", "regs", "occupied_slices",
            "logic_levels", "wns_ns", "unrouted", "dyn_power_mw",
            "static_power_mw", "total_power_mw"]
    with open(a.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(out)
    print(f"wrote {a.out} ({len(out)} designs)")


if __name__ == "__main__":
    main()
