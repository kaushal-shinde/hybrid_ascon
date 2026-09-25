#!/usr/bin/env python3
"""Rebuild hardware_analysis.xlsx from graphs/results.csv.

Unlike the generator this replaces, nothing here is hardcoded: every measured
number is read from the CSV that run_vivado.sh / run_sky130.sh produce, so the
workbook cannot drift away from the data.

The only per-design constants are bits-per-cycle, which come from each design's
RTL cycle schedule (RESULTS.md 5) and are unchanged by re-measurement -- the
same value reproduces both the FPGA and ASIC throughput of the previous
published workbook to within rounding.

Usage: python3 build_hw_xlsx.py [--csv F] [--out F]
"""
import argparse, csv, os

import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# design -> bits absorbed/emitted per clock cycle (rate / cycles-per-block).
# elephant is a bracket: its block-boundary cost is not a repeatable constant.
BITS_PER_CYCLE = {
    "Ascon-AEAD128": 16.0,      # 128-bit rate / 8 cycles  (p^12 / p^8)
    "SipCon64":   64.0 / 6,  #  64-bit rate / 6 cycles  (p^10 / p^6)
    "tinyjambu":      0.8873,
    "xoodyak":       10.667,
    "giftcofb":       2.2432,
    "grain128aead":   0.4655,
    "sparkle":        7.325,
    "elephant":      (0.95, 1.90),
    "isap":           1.5990,
    "photonbeetle":   5.2269,
    "romulus":        2.7828,
}

NOTE = "vectorless (default activity estimate)"

TITLE_FONT = Font(bold=True, size=14)
SUB_FONT = Font(italic=True, size=9, color="555555")
HDR_FONT = Font(bold=True, color="FFFFFF")
HDR_FILL = PatternFill("solid", fgColor="365F91")
BEST_FILL = PatternFill("solid", fgColor="C6EFCE")
THIN = Side(style="thin", color="BFBFBF")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def rng(v, f):
    """Format a scalar or a (lo, hi) bracket."""
    return f"{f(v[0])}-{f(v[1])}" if isinstance(v, tuple) else f(v)


def thr_of(design, fmax):
    b = BITS_PER_CYCLE[design]
    return (b[0] * fmax, b[1] * fmax) if isinstance(b, tuple) else b * fmax


def sheet(wb, title, subtitle, headers, rows, best_cols, widths):
    ws = wb.create_sheet(title)
    ws["A1"] = title.split(" (")[0] + " results"
    ws["A1"].font = TITLE_FONT
    ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=len(headers))
    ws["A2"] = subtitle
    ws["A2"].font = SUB_FONT
    ws.merge_cells(start_row=2, start_column=1, end_row=2, end_column=len(headers))

    for c, h in enumerate(headers, 1):
        cell = ws.cell(4, c, h)
        cell.font, cell.fill, cell.border = HDR_FONT, HDR_FILL, BOX
        cell.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
    ws.row_dimensions[4].height = 42

    for r, row in enumerate(rows, 5):
        for c, v in enumerate(row, 1):
            cell = ws.cell(r, c, v)
            cell.border = BOX
            if c > 1:
                cell.alignment = Alignment(horizontal="right")

    # highlight the best value in each nominated column (smallest or largest)
    for col, smaller_is_better in best_cols.items():
        vals = []
        for r in range(5, 5 + len(rows)):
            v = ws.cell(r, col).value
            if isinstance(v, (int, float)):
                vals.append((v, r))
        if not vals:
            continue
        target = min(vals)[1] if smaller_is_better else max(vals)[1]
        ws.cell(target, col).fill = BEST_FILL

    ws.cell(5 + len(rows) + 1, 1,
            "Green = best in column. Ranges (elephant) are excluded from the "
            "comparison, since they are brackets rather than point estimates.")
    ws.cell(5 + len(rows) + 1, 1).font = SUB_FONT
    for c, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(c)].width = w
    ws.freeze_panes = "B5"
    return ws


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=os.path.join(ROOT, "graphs", "results.csv"))
    ap.add_argument("--out", default=os.path.join(ROOT, "hardware_analysis.xlsx"))
    a = ap.parse_args()

    data = list(csv.DictReader(open(a.csv)))
    wb = openpyxl.Workbook()
    wb.remove(wb.active)

    # ------------------------------------------------------------------ FPGA
    fpga_rows = []
    for d in data:
        n = d["design"]
        fmax = float(d["fpga_fmax_mhz"])
        luts = int(d["fpga_lut"])
        pw = float(d["fpga_power_mw"])
        thr = thr_of(n, fmax)
        ta = (thr[0] / luts, thr[1] / luts) if isinstance(thr, tuple) else thr / luts
        eb = ((pw / thr[1] * 1000, pw / thr[0] * 1000) if isinstance(thr, tuple)
              else pw / thr * 1000)
        fpga_rows.append([
            n, luts, int(d["fpga_reg"]), round(1000.0 / fmax, 3), fmax, pw, NOTE,
            rng(thr, lambda x: f"{x:.1f}"),
            rng(ta, lambda x: f"{x:.4f}"),
            rng(eb, lambda x: f"{x:.1f}"),
        ])
    sheet(wb, "FPGA (Vivado)",
          "Source: graphs/results.csv, produced by flow/run_vivado.sh -- Vivado 2026.1, "
          "xc7a12ticsg325-1L, out-of-context, single-threaded, identical 7-iteration "
          "period search for all 11 designs. Power is vectorless for every design.",
          ["Design", "Area - Slice LUTs", "Area - Slice Registers",
           "Critical Path Delay (ns)", "Max Frequency (MHz)", "Power (mW)",
           "Power source", "Throughput (Mbit/s)",
           "Throughput / Area (Mbit/s per LUT)", "Energy / bit (pJ)"],
          fpga_rows, {2: True, 5: False, 6: True}, [17, 12, 12, 12, 12, 10, 24, 14, 15, 13])

    # ------------------------------------------------------------------ ASIC
    asic_rows = []
    for d in data:
        n = d["design"]
        fmax = float(d["sky130_fmax_mhz"])
        area = float(d["sky130_area_um2"])
        pw = float(d["sky130_power_mw"])
        thr = thr_of(n, fmax)
        # Gbit/s per mm^2
        ta = ((thr[0] * 1000 / area, thr[1] * 1000 / area) if isinstance(thr, tuple)
              else thr * 1000 / area)
        eb = ((pw / thr[1] * 1000, pw / thr[0] * 1000) if isinstance(thr, tuple)
              else pw / thr * 1000)
        asic_rows.append([
            n, int(area), int(d["sky130_ge"]), round(1000.0 / fmax, 3), fmax, pw, NOTE,
            rng(thr, lambda x: f"{x:.1f}"),
            rng(ta, lambda x: f"{x:.3f}"),
            rng(eb, lambda x: f"{x:.1f}"),
        ])
    sheet(wb, "ASIC (sky130hd)",
          "Source: graphs/results.csv, produced by flow/run_sky130.sh -- yosys 0.38 + "
          "OpenROAD 2.0 on sky130hd (tt_025C_1v80), identical period search for all 11 "
          "designs, stopped after global routing. Power is vectorless for every design.",
          ["Design", "Area (um^2)", "Gate Equivalents (GE)",
           "Critical Path Delay (ns)", "Max Frequency (MHz)", "Power (mW)",
           "Power source", "Throughput (Mbit/s)",
           "Throughput / Area (Gbit/s per mm^2)", "Energy / bit (pJ)"],
          asic_rows, {2: True, 5: False, 6: True}, [17, 13, 13, 12, 12, 10, 24, 14, 16, 13])

    # ----------------------------------------------------------------- notes
    ws = wb.create_sheet("Notes & Caveats")
    ws["A1"] = "Notes, methodology and caveats"
    ws["A1"].font = TITLE_FONT
    notes = [
        ("Scope", "All 11 designs in verilog/: Ascon-AEAD128 (NIST SP 800-232), one "
                  "experimental SipCon64 hybrid (r=64), and the 9 NIST LWC finalists "
                  "that lost to Ascon."),
        ("One flow, all eleven", "Every figure on both sheets comes from a single "
                  "measurement procedure applied identically to all 11 designs: the same "
                  "period search, the same tool versions, the same power method. The "
                  "previous edition of this workbook mixed two passes -- a deeper one for "
                  "the 2 Ascon-family designs and a lighter survey for the 9 finalists -- "
                  "which made several columns not directly comparable across rows. That "
                  "asymmetry is gone."),
        ("Numbers differ from the previous edition", "These are a fresh measurement, not a "
                  "correction of individual figures. The original flow scripts were lost, "
                  "so the flow was rebuilt (flow/ in this repository) and all 11 designs "
                  "re-measured on Vivado 2026.1 and OpenROAD 2.0. Register counts reproduce "
                  "exactly on all 11 designs and sky130 area reproduces within a few percent "
                  "on the 9 finalists, which is the evidence that the rebuild is sound. See "
                  "RESULTS.md for what changed and why."),
        ("Power is vectorless everywhere", "Both sheets' power is a vectorless "
                  "default-activity estimate for all 11 designs. The previous edition had "
                  "simulation-derived activity (SAIF on FPGA, VCD on sky130) for the 2 "
                  "Ascon-family designs; that stimulus was not kept and could not be "
                  "reproduced. This makes the column uniform across rows, but it is a real "
                  "accuracy downgrade for those two designs. Read vectorless power as "
                  "relative ordering, not absolute silicon power."),
        ("Energy / bit", "power / throughput, using total power, consistently for all 11 "
                  "designs. The previous edition divided by dynamic-only power for the 2 "
                  "Ascon-family FPGA rows and total power for the other 9, so its FPGA "
                  "energy/bit column was not comparable across rows. This one is."),
        ("Throughput methodology", "throughput = Max Frequency x bits-per-cycle, where "
                  "bits-per-cycle is each design's own RTL cycle schedule (RESULTS.md 5). "
                  "That schedule is a property of the RTL and is unchanged by "
                  "re-measurement; the same constants reproduce the previous edition's "
                  "throughput figures to within rounding."),
        ("Elephant - bracket, not a point estimate", "elephant's block-boundary crossing is "
                  "not a repeatable constant: the first Spongent-pi[160] call costs 84 "
                  "cycles, but crossing the second block costs two back-to-back (169), not "
                  "one. Both bounds are real, simulation-observed numbers, so its throughput, "
                  "throughput/area and energy/bit are ranges and are excluded from the "
                  "best-in-column highlighting."),
        ("sparkle floorplan", "sparkle is the only design that would not route at the "
                  "45% target utilization used for the other ten; it was placed at 30% "
                  "instead. Area here is summed instance area, which is unaffected by "
                  "floorplan utilization, so the comparison holds."),
        ("Area definitions", "FPGA area = Slice LUTs, with Slice Registers alongside. ASIC "
                  "area = summed placed-instance area in um^2 after global routing; GE = "
                  "that area divided by the sky130hd NAND2_1 cell area of 3.7536 um^2."),
        ("Critical path delay", "The best period each design closed at under an identical "
                  "binary search, with zero unrouted nets (FPGA) and non-negative worst "
                  "slack. Max Frequency = 1 / Critical Path Delay."),
        ("Not security claims", "Smaller / faster / lower-power is not 'better' in "
                  "isolation -- these 11 designs have different key/tag sizes, round counts "
                  "and security margins, and the hybrid is an unanalysed construction with "
                  "no cryptanalysis. See RESULTS.md 8 before treating any number here as a "
                  "security or deployment recommendation."),
        ("Source of truth", "graphs/results.csv in this repository, written by "
                  "flow/merge_results.py from the two sweep CSVs. This workbook adds only "
                  "derived columns (throughput, throughput/area, energy/bit) and hardcodes "
                  "no measured value."),
        ("Generated", "2026-09-07, by flow/build_hw_xlsx.py."),
    ]
    r = 3
    for t, b in notes:
        ws.cell(r, 1, t).font = Font(bold=True)
        ws.cell(r, 1).alignment = Alignment(vertical="top")
        c = ws.cell(r, 2, b)
        c.alignment = Alignment(wrap_text=True, vertical="top")
        r += 2
    ws.column_dimensions["A"].width = 34
    ws.column_dimensions["B"].width = 110

    wb.save(a.out)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
