#!/usr/bin/env python3
"""Rebuild software_analysis.xlsx from software/results.csv + curve_results.csv.

Nothing measured is hardcoded here: every number is read from the CSVs that
software/bench/run_all.sh produces, so the workbook cannot drift from the data.
Only per-design metadata (key sizes, round schedule, RTL verification status)
lives in this file, since it is not in the CSVs.

Usage: python3 build_sw_xlsx.py [--csv F] [--curve F] [--out F]
"""
import argparse, csv, os, collections

import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# design -> (key/npub/tag, rate B/call, round schedule, RTL verification status, detail)
META = {
    "Ascon-AEAD128": ("16/16/16", 16, "12 init/final + 8 per block", "KAT-verified",
        "1089/1089 official NIST-format vectors, both directions"),
    "hybrid r=64": ("16/16/16", 8, "10 init/final + 6 per block", "C/RTL cross-checked",
        "Round counts changed to p^10/p^6 on 2026-09-08; the earlier 1089-vector "
        "self-generated KAT was produced from the p^12/p^8 reference and NO LONGER "
        "APPLIES. Current evidence is a directed Vivado xsim run (24B AD / 40B message) "
        "in which the RTL's ciphertext blocks and 128-bit tag match the C reference "
        "exactly, plus the C's own encrypt/decrypt round-trip and tamper-rejection. "
        "No official KAT suite exists for this construction (not a NIST submission)."),
    "TinyJAMBU-128": ("16/12/8", 4, "1024 (key setup) + 640/1152 (frame)", "KAT-verified",
        "17127/17127 words, official NIST KAT suite"),
    "Xoodyak": ("16/16/16", 16, "12 (fixed, every call)", "KAT-verified",
        "19305/19305 words, after fixing 6 real RTL bugs"),
    "GIFT-COFB": ("16/16/16", 16, "40 (GIFT-128)", "KAT-verified",
        "19305/19305 words, after fixing 9 real RTL bugs"),
    "Grain-128AEAD": ("16/12/8", 1, "320 (init) + 256 (key/acc load)", "KAT-verified",
        "17127/17127 words, after fixing 5 real RTL bugs"),
    "SPARKLE": ("16/32/16", 32, "7 (slim) / 11 (big)", "KAT-verified",
        "19305/19305 words, after fixing 1 real RTL bug"),
    "Elephant (Dumbo)": ("16/12/8", 20, "80 (Spongent-pi[160])", "KAT-verified",
        "17127/17127 words, after fixing 5 real RTL bugs"),
    "ISAP (ISAP-A-128A)": ("16/16/16", 8, "sH=12 sB=1 sE=6 sK=12 (phase-dependent)",
        "KAT-verified", "19305/19305 words, after fixing 4 real RTL bugs"),
    "PHOTON-Beetle": ("16/16/16", 16, "12 (PHOTON256)", "KAT-verified",
        "19305/19305 words, after fixing 9 real RTL bugs"),
    "Romulus (Romulus-N)": ("16/16/16", 16, "40 (SKINNY-128-384+)", "KAT-verified",
        "19305/19305 words, after fixing 3 real RTL bugs"),
}

TITLE_FONT = Font(bold=True, size=14)
SUB_FONT = Font(italic=True, size=9, color="555555")
HDR_FONT = Font(bold=True, color="FFFFFF")
HDR_FILL = PatternFill("solid", fgColor="365F91")
BEST_FILL = PatternFill("solid", fgColor="C6EFCE")
THIN = Side(style="thin", color="BFBFBF")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def header(ws, headers, row, widths):
    for c, h in enumerate(headers, 1):
        cell = ws.cell(row, c, h)
        cell.font, cell.fill, cell.border = HDR_FONT, HDR_FILL, BOX
        cell.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
    ws.row_dimensions[row].height = 46
    for c, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(c)].width = w


def best(ws, first_row, n, col, smaller_is_better):
    vals = [(ws.cell(r, col).value, r) for r in range(first_row, first_row + n)
            if isinstance(ws.cell(r, col).value, (int, float))]
    if vals:
        ws.cell((min(vals) if smaller_is_better else max(vals))[1], col).fill = BEST_FILL


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv",   default=os.path.join(ROOT, "software", "results.csv"))
    ap.add_argument("--curve", default=os.path.join(ROOT, "software", "curve_results.csv"))
    ap.add_argument("--out",   default=os.path.join(ROOT, "software_analysis.xlsx"))
    a = ap.parse_args()

    rows = sorted(csv.DictReader(open(a.csv)), key=lambda r: int(r["rom_bytes"]))
    curve = collections.defaultdict(dict)
    for r in csv.DictReader(open(a.curve)):
        curve[r["design"]][int(r["size_bytes"])] = float(r["cycles_per_byte"])

    wb = openpyxl.Workbook()
    wb.remove(wb.active)

    # ------------------------------------------------------------ main sheet
    ws = wb.create_sheet("Software (x86_64 native)")
    ws["A1"] = "Software Analysis - reference C, native x86_64"
    ws["A1"].font = TITLE_FONT
    ws["A2"] = ("Source: software/results.csv, produced by software/bench/run_all.sh. "
                "GCC -O2 -fPIC, no LTO. Best-of-N timing; latency at 16B/16B, "
                "cycles-per-byte and throughput at 4096B.")
    ws["A2"].font = SUB_FONT
    ws["A3"] = ("CPU: Intel Core i7-6700, powersave governor (NOT pinned) - see the "
                "timing-variance note; cycles/byte is far more stable than throughput.")
    ws["A3"].font = SUB_FONT
    cols = ["Design", "Key/Npub/Tag (bytes)", "Rate (B/call)", "Rounds",
            "ROM total (bytes)", "ROM .text (bytes)", "ROM .rodata (bytes)",
            "RAM (bytes)", "Stack (bytes)", "Enc Latency (cycles)", "Enc Cycles/byte",
            "Enc Throughput (MB/s)", "Dec Latency (cycles)", "Dec Cycles/byte",
            "Dec Throughput (MB/s)", "Dec Round-trip OK", "RTL verification status",
            "RTL verification detail"]
    header(ws, cols, 5,
           [21, 17, 11, 30, 12, 12, 13, 10, 11, 13, 12, 14, 13, 12, 14, 12, 20, 62])
    for i, d in enumerate(rows):
        n = d["design"]
        m = META[n]
        ws.append([]) if False else None
        vals = [n, m[0], m[1], m[2],
                int(d["rom_bytes"]), int(d["rom_dot_text_bytes"]), int(d["rom_dot_rodata_bytes"]),
                int(d["ram_bytes"]), int(d["stack_bytes"]),
                int(float(d["latency_cycles"])), round(float(d["cycles_per_byte"]), 2),
                round(float(d["throughput_MBps"]), 2),
                int(float(d["dec_latency_cycles"])), round(float(d["dec_cycles_per_byte"]), 2),
                round(float(d["dec_throughput_MBps"]), 2),
                "yes" if d["dec_roundtrip_ok"] == "1" else "NO", m[3], m[4]]
        for c, v in enumerate(vals, 1):
            cell = ws.cell(6 + i, c, v)
            cell.border = BOX
            if c in (18, 17, 4):
                cell.alignment = Alignment(wrap_text=True, vertical="top")
            elif c > 1:
                cell.alignment = Alignment(horizontal="right")
    for col, smaller in [(5, True), (8, True), (9, True), (10, True), (11, True), (12, False)]:
        best(ws, 6, len(rows), col, smaller)
    ws.freeze_panes = "B6"

    # ----------------------------------------------------------- curve sheet
    ws2 = wb.create_sheet("Throughput Curve")
    ws2["A1"] = "Throughput curve - cycles/byte vs message size (encrypt)"
    ws2["A1"].font = TITLE_FONT
    ws2["A2"] = ("Source: software/curve_results.csv. Separates fixed per-call setup cost "
                 "from steady-state per-byte cost, which the single 4096B point cannot show.")
    ws2["A2"].font = SUB_FONT
    sizes = [16, 64, 256, 1024, 4096]
    header(ws2, ["Design"] + [f"{s}B cyc/byte" for s in sizes] + ["Ratio 16B/4096B"], 4,
           [21, 14, 14, 14, 15, 15, 16])
    for i, d in enumerate(rows):
        n = d["design"]
        c = curve.get(n, {})
        vals = [n] + [round(c[s], 2) if s in c else "" for s in sizes]
        vals.append(round(c[16] / c[4096], 2) if 16 in c and 4096 in c else "")
        for j, v in enumerate(vals, 1):
            cell = ws2.cell(5 + i, j, v)
            cell.border = BOX
            if j > 1:
                cell.alignment = Alignment(horizontal="right")
    ws2.freeze_panes = "B5"

    # ----------------------------------------------------------- notes sheet
    ws3 = wb.create_sheet("Notes & Caveats")
    ws3["A1"] = "Notes, methodology and caveats"
    ws3["A1"].font = TITLE_FONT
    notes = [
        ("Scope", "All 11 designs' *official reference C* (not the Verilog RTL that "
            "RESULTS.md / hardware_analysis.xlsx measure): Ascon-AEAD128, one experimental "
            "Ascon-SipHash hybrid (r=64), and the 9 NIST LWC finalists. Compiled natively "
            "for x86_64 -- not an embedded target."),
        ("The hybrid's round counts changed", "The hybrid was reduced from p^12/p^8 to "
            "p^10/p^6 on 2026-09-08. Its numbers here are for the new schedule and are NOT "
            "comparable with earlier editions of this workbook. The reduction was taken for "
            "throughput; it lowers the security margin of a construction that has had no "
            "cryptanalysis to justify either the old or the new number."),
        ("What 'verified' means here", "The verification columns describe the *hardware "
            "RTL's* status, carried over for context -- they are not a claim about this "
            "report's own C measurements. Note the hybrid's entry in particular: its "
            "self-generated KAT vectors predate the round change and no longer apply."),
        ("Decrypt columns", "Same methodology as encrypt: same message shapes, same "
            "best-of-N timing. 'Dec Round-trip OK' = decrypt(encrypt(m)) returned success "
            "and matched the original plaintext byte-for-byte on every rep. That checks the "
            "harness's own DECRYPT_FN wiring, not cryptographic correctness."),
        ("ROM total vs .text/.rodata -- read before quoting ROM", "'ROM total' is NOT just "
            "code size: 11-59% of it (design-dependent) is shared-library/ELF metadata that "
            "exists only because this harness builds each algorithm as a -fPIC shared object "
            "for dlopen(). '.text' and '.rodata' are the real code and table sizes."),
        ("Native x86_64, not embedded", "No ARM/AVR/RISC-V cross-compiler was used. "
            "ROM/RAM/stack absolute numbers will not match published Cortex-M0 or ATmega "
            "figures. Relative ordering between designs travels better than absolute "
            "numbers do."),
        ("Reference C, not hand-tuned", "Several algorithms have faster published "
            "implementations (bitsliced, SIMD, platform-specific) not measured here. This "
            "measures what each submission ships as its reference -- a baseline, not a "
            "ceiling. Ascon's own reference is explicitly labelled 'highly optimized' and "
            "is markedly larger in ROM as a result."),
        ("Elephant and PHOTON-Beetle are legitimate outliers", "Orders of magnitude slower "
            "in cycles/byte than the fastest designs here, because their reference C "
            "implements bit/nibble-serial operations a general-purpose CPU is bad at -- and "
            "hardware measures both as unremarkable-to-competitive. Same algorithm, opposite "
            "verdict, depending which cost model you read."),
        ("Energy is not measured", "RAPL and perf energy counters both need elevated "
            "permissions unavailable on this machine, and a derived proxy was deliberately "
            "not fabricated. Contrast hardware_analysis.xlsx, where power is measured."),
        ("Timing variance", "The governor is `powersave`, not pinned. Effective clock rate "
            "implied by cycles_per_byte vs wall-clock throughput is not fixed across runs: "
            "2.79-3.87 GHz (2026-09-04), 3.06-3.30 GHz (2026-09-05), 2.79-3.16 GHz "
            "(2026-09-07). Prefer cycles/byte over throughput when comparing across runs; "
            "ROM/RAM/stack are byte-identical across every rerun."),
        ("RAM vs stack", "Different questions, don't sum them: RAM (.data+.bss) is a fixed "
            "permanent budget; stack is a transient worst-case call-chain depth for one "
            "operation."),
        ("Not security claims", "Smaller / faster / less RAM is not 'better' in isolation -- "
            "these 11 designs have different key/tag sizes, round counts and security "
            "margins, and the hybrid is an unanalysed construction whose margin was just "
            "reduced further. See RESULTS.md 8 before treating any number here as a "
            "deployment recommendation."),
        ("Source of truth", "software/results.csv and software/curve_results.csv in this "
            "repository, produced by software/bench/run_all.sh. This workbook hardcodes no "
            "measured value; it adds only rounding for display and the 16B/4096B ratio."),
        ("Generated", "2026-09-08, by flow/build_sw_xlsx.py."),
    ]
    r = 3
    for t, b in notes:
        ws3.cell(r, 1, t).font = Font(bold=True)
        ws3.cell(r, 1).alignment = Alignment(vertical="top")
        ws3.cell(r, 2, b).alignment = Alignment(wrap_text=True, vertical="top")
        r += 2
    ws3.column_dimensions["A"].width = 36
    ws3.column_dimensions["B"].width = 108

    wb.save(a.out)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
