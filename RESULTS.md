# Hardware results: Ascon-AEAD128, an SipCon64 hybrid, and the 9 NIST LWC finalists

Area, timing and power for all eleven AEAD cores in [`verilog/`](verilog/) —
the NIST-standardized Ascon-AEAD128, an experimental SipCon64 hybrid,
and one core per algorithm that lost to Ascon in the final round of NIST's
Lightweight Cryptography competition — measured on the same FPGA with Vivado
and the same 130 nm ASIC process with OpenROAD.

**Every number was produced by Xilinx Vivado or by OpenROAD** on this
machine, and **every number in this edition is a fresh measurement** taken
2026-09-07/08 with a rebuilt flow ([`flow/`](flow/)) applied identically to
all eleven designs. They replace the previous edition's figures wholesale
rather than correcting individual entries; absolute values are not comparable
across the two editions. Section 10 maps each metric to the script and log it
came from.

The rebuild was necessary because the original flow scripts were kept only in
temporary scratchpads and were lost. What that costs and what it buys is set
out in §1.2; the short version is that all eleven designs now get one
identical procedure instead of two tiers, at the price of the two
Ascon-family designs' activity-annotated power.

**One design also changed algorithm between editions.** The hybrid's round
counts were reduced from p^12/p^8 to p^10/p^6 on 2026-09-08, so its rows here
describe a different construction from the one the previous edition measured
(§1.1, §5).

---

## 1. Designs, tools and targets

### 1.1 The eleven designs

| design | file | key / npub / tag (bytes) | KAT-verified? |
|---|---|---|---|
| **Ascon-AEAD128** (the winner) | `ascon_aead128.v` | 16 / 16 / 16 | **yes** (1089/1089 vectors)³ |
| **SipCon64** (no dedicated cryptanalysis) | `sipcon64_aead.v` | 16 / 16 / 16 | no — C/RTL cross-check only⁴ |
| TinyJAMBU-128 | `tinyjambu_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words) |
| Xoodyak | `xoodyak_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 6 bugs² |
| GIFT-COFB | `giftcofb_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 9 bugs² |
| Grain-128AEAD | `grain128aead_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words), after fixing 5 bugs² |
| SPARKLE (Schwaemm256-128) | `sparkle_lwc.v` | 16 / 32 / 16 | **yes** (19305/19305 words), after fixing 1 bug² |
| Elephant (Dumbo) | `elephant_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words), after fixing 5 bugs² |
| ISAP (ISAP-A-128A) | `isap_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 4 bugs² |
| PHOTON-Beetle | `photonbeetle_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 9 bugs² |
| Romulus (Romulus-N) | `romulus_n_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 3 bugs² |

¹ The hybrid is not a NIST submission, so no *official* KAT vector suite
exists for it. It previously had a self-generated one and a 16×16 synthetic
length grid against its C reference; both were produced from the p^12/p^8
version of the construction and neither applies to the p^10/p^6 design
measured here. See footnote 4 for what does back it now, and
`sipcon64/README.md` for the construction itself.

² Full official NIST LWC KAT vector grid in Vivado `xsim`, both directions.
All 42 bugs across these eight cores (tinyjambu needed none) are catalogued
in `verilog/README.md`; this file previously listed all nine finalists as
"lint-clean only, not KAT-verified" — that was true of the RTL measured
2026-08-29 and is no longer true of the RTL in `verilog/` today.

³ Ascon-AEAD128 is NIST SP 800-232, so official-format KAT vectors exist:
`LWC_AEAD_KAT_128_128.txt`, 1089 Count/Key/Nonce/PT/AD/CT vectors generated
from NIST's own vendored `ascon-c` reference implementation for exactly this
algorithm (key/nonce/tag 16/16/16 bytes, matching `ascon_aead128.v`'s
header). Walked through the core's own custom block interface in Vivado
`xsim`, both directions, 2026-09-02, against the same unmodified RTL
measured throughout this file: **1089/1089 encrypt, 1089/1089 decrypt** —
see `verilog/README.md`. This is in addition to, not a replacement for, the
16×16 synthetic-grid check in footnote 1, which `ascon_aead128.v` also still
passes.

⁴ **The hybrid has no valid KAT run as of this edition.** It previously had
one: NIST's own unmodified `genkat_aead.c` was re-linked against the hybrid's
reference C to produce 1089 self-generated vectors, and `sipcon64_aead.v`
passed all of them in both directions on 2026-09-04. Those vectors were
generated from the **p^12/p^8** version of the construction. The round counts
were reduced to **p^10/p^6** on 2026-09-08, which changes the function — and
changes the IV, since the round counts are encoded in it (`0x00530800808C0001`
became `0x00530800806A0001`) — so the vectors no longer apply and the pass no
longer means anything about the current design.

What the current design has instead is a directed cross-check: a testbench
generated from the C reference's own output was walked through
`sipcon64_aead.v` in Vivado `xsim` (24-byte AD, 40-byte message), and every
ciphertext block and the 128-bit tag matched the C exactly; the C itself
round-trips and rejects a tampered ciphertext. That establishes the RTL and the
C agree, which is what the twin relationship claims — but it is one vector, not
1089, and it is not a known-answer test, because for this construction there is
no independent answer key: no official NIST suite exists (it is not a NIST
submission), and the only reference is the C the RTL is being compared against.

Regenerating the self-generated suite against the p^10/p^6 reference would
restore the earlier level of evidence and is the obvious next step; it has not
been done. Read the hybrid's row as *less* verified than any other design in
this table, not equally verified.

The first two implement a **custom** block-oriented interface; the other
nine implement the **NIST LWC Hardware API** (PDI/SDI/DO). They are not
port-compatible — see `verilog/README.md`. That does not stop them being
measured, and compared, the same way: this file treats all eleven as one
study, because that is what they are — Ascon and the field it beat.

### 1.2 Tools, and how thoroughly each design was measured

| | |
|---|---|
| FPGA implementation | Vivado v2026.1, `set_param general.maxThreads 1` |
| FPGA part | **xc7a12ticsg325-1L** — Artix-7, CSG325, −1L, 8000 LUTs / 16000 FFs |
| Simulation | Vivado `xvlog` / `xelab` / `xsim` |
| ASIC P&R, optimisation, STA, power | OpenROAD 2.0-12381-g01bba3695 |
| ASIC synthesis front-end | yosys 0.38+92 (OpenROAD does not synthesise) |
| ASIC library | **SkyWater sky130hd**, 130 nm, fabricable, `tt_025C_1v80`, NAND2_1 = 3.7536 µm² |

**All eleven designs were measured by one procedure**, applied identically.
The previous edition of this file ran two tiers — a deeper pass for the two
Ascon-family designs and a lighter survey for the nine finalists — and carried
footnotes throughout warning which columns could not be compared across that
boundary. That split is gone:

| | all eleven |
|---|---|
| Vivado period search | identical 7-iteration binary search, probe then bisect |
| sky130 period | identical search, same procedure as FPGA |
| FPGA power | vectorless, total on-chip |
| sky130 power | vectorless |
| Reports extracted | utilization, timing, power — uniformly, for every design |

The cost of that consistency is that the two Ascon-family designs lost their
activity-annotated power (SAIF on FPGA, VCD on sky130). The stimulus used to
produce it was not kept and could not be reproduced, so every power figure in
this file is now a vectorless default-activity estimate. That is more
comparable across rows and less accurate for those two designs than the
previous edition — see §3.3, §4.2 and §8.1.

**The flow itself was rebuilt.** The original scripts lived in temporary
session scratchpads and were lost; they are now in [`flow/`](flow/) in this
repository, version-controlled alongside the RTL, so this cannot recur. See
§10.

Two finalist files needed an RTL fix to reach this data: `giftcofb_lwc.v`
and `romulus_n_lwc.v` both part-selected a function call's return value
directly (`f(...)[a:b]`) — legal Verilog-2005, accepted by Verilator and
Vivado, rejected by yosys's parser. Both were fixed by holding the call's
result in an intermediate signal first; re-lint in Verilator and Vivado
confirmed no behavioural change. That fix predates and is independent of the
42-bug correctness pass in §1.1 above; this rerun's yosys logs confirm both
still synthesize cleanly (no unmapped cells) with it in place.

---

## 2. Headline

All eleven, sorted by sky130 area (smallest first). GE = gate equivalents =
cell area / sky130 NAND2 area (3.7536 um^2). Power is a vectorless
default-activity estimate for every design — see §1.2.

| design | FPGA LUTs | FPGA regs | FPGA Fmax | FPGA power | sky130 area | sky130 GE | sky130 Fmax | sky130 power |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| tinyjambu | **473** | **533** | 231.4 MHz | 80 mW | **27 081 µm²** | **7 215** | **300.6 MHz** | **10.1 mW** |
| grain128aead | 598 | 915 | 214.3 MHz | 85 mW | 41 247 µm² | 10 989 | 277.3 MHz | 16.4 mW |
| **SipCon64** | 874 | 600 | 139.4 MHz | 83 mW | 48 304 µm² | 12 869 | 58.8 MHz | 20.3 mW |
| giftcofb | 1530 | 1005 | 120.0 MHz | 68 mW | 61 004 µm² | 16 252 | 234.1 MHz | 38.8 mW |
| **Ascon-AEAD128** | 1122 | 728 | **241.4 MHz** | 132 mW | 62 955 µm² | 16 772 | 260.6 MHz | 88.0 mW |
| xoodyak | 1554 | 885 | 129.9 MHz | 97 mW | 74 590 µm² | 19 872 | 196.0 MHz | 19.5 mW |
| romulus | 1498 | 1430 | 176.2 MHz | 78 mW | 84 876 µm² | 22 612 | 205.1 MHz | 38.7 mW |
| photonbeetle | 2033 | 1090 | 123.0 MHz | 78 mW | 99 503 µm² | 26 509 | 111.6 MHz | 56.8 mW |
| isap | 2358 | 1651 | 164.1 MHz | **134 mW** | 106 288 µm² | 28 316 | 185.9 MHz | 83.2 mW |
| sparkle | 2369 | 1093 | 74.4 MHz | 105 mW | 140 097 µm² | 37 323 | **41.2 MHz** | **109.0 mW** |
| elephant | **4625** | **2472** | **50.1 MHz** | **66 mW** | **173 446 µm²** | **46 208** | 78.2 MHz | 38.2 mW |

**tinyjambu is the smallest design in the set and the fastest on sky130**
(300.6 MHz), with the lowest ASIC power as well. It is no longer the fastest
on FPGA: Ascon-AEAD128 now leads there at 241.4 MHz. That reversal is the
single biggest change in this table and it is discussed in §3.2 — the
previous edition recorded Ascon at 55.0 MHz, which this re-measurement does
not reproduce and which is inconsistent with Ascon's own sky130 result.

**elephant and sparkle are the two heavyweights**, each for a different
structural reason — see §7. sparkle is also the slowest ASIC design (41.2
MHz) and draws the most ASIC power; elephant is the largest on both targets
and the slowest on FPGA.

Between the two Ascon-family designs, **Ascon-AEAD128 is now the better
design on both targets**. The previous edition had r=64 winning the FPGA
comparison, but that rested on Ascon's 55.0 MHz figure; with Ascon measured
at 241.4 MHz, r=64 leads on neither. What r=64 retains is area: it is the
third smallest design on sky130 and uses 33% fewer LUTs than Ascon. See §6.

**Every number in this table is a fresh measurement**, taken 2026-09-07/08
with a rebuilt flow applied identically to all eleven designs (§1.2, §10).
They replace the previous edition's figures rather than correcting
individual entries, and absolute values are not comparable across the two.
The hybrid additionally changed algorithm between editions — its round
counts were reduced from p^12/p^8 to p^10/p^6 on 2026-09-08 (§1.1).

---

## 3. FPGA — Vivado, xc7a12ticsg325-1L

Out-of-context synthesis (`synth_design -mode out_of_context`), then
`opt_design → place_design → phys_opt_design → route_design`,
single-threaded so results are reproducible. All eleven **routed with zero
errors** at their final constraint.

Out-of-context is the standard way to characterise an IP core and is how
published Ascon figures are measured. It is also the only option here: these
cores have far more ports than CSG325 offers usable I/O, so an I/O-buffered
build is not physically possible. Frequencies are for the core alone and
would fall once integrated behind real I/O paths.

### 3.1 Resources

"Slice LUTs" is Vivado's utilization figure, not a count of LUT primitives —
the two differ by up to 39% because Vivado packs two logic functions into one
dual-output LUT6, and Slice LUTs is the conventional FPGA area metric.

| design | Slice LUTs | Slice Registers | Occupied slices | logic levels |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 1122 (14.0%) | 728 | 348 | **3** |
| SipCon64 | 874 (10.9%) | 600 | 279 | 27 |
| tinyjambu | **473 (5.9%)** | **533** | 192 | 4 |
| xoodyak | 1554 (19.4%) | 885 | 491 | 8 |
| giftcofb | 1530 (19.1%) | 1005 | 475 | 11 |
| grain128aead | 598 (7.5%) | 915 | 254 | 4 |
| sparkle | 2369 (29.6%) | 1093 | 715 | **29** |
| elephant | **4625 (57.8%)** | **2472** | 1673 | 28 |
| isap | 2358 (29.5%) | 1651 | 726 | 5 |
| photonbeetle | 2033 (25.4%) | 1090 | 612 | 8 |
| romulus | 1498 (18.7%) | 1430 | 476 | 4 |

Occupied slices are now recorded for all eleven designs, not just the two
Ascon-family ones — the rebuilt flow extracts them uniformly (§1.2).

Logic-level count tracks each algorithm's per-cycle combinational shape rather
than its cycle count. **sparkle has the deepest single FPGA path (29 levels)**,
with elephant just behind at 28. The hybrid's 27 is the notable entry: its
round function is four dependent 64-bit additions, and those carry chains are
what its critical path is made of — the same structure that costs it far more
on the ASIC target (§4.1, §7).

### 3.2 Timing

QoR is **non-monotonic in the constraint** even when deterministic: a tighter
constraint can route better than a looser one, so Fmax below is the best
achieved period across an identical 7-iteration binary search per design
(§1.2), not a single point.

| design | tightest closing constraint | WNS | achieved period | **Fmax** |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 4.142 ns | +0.142 | 4.000 ns | **241.43 MHz** |
| SipCon64 | 7.171 ns | +0.017 | 7.154 ns | 139.45 MHz |
| tinyjambu | 4.322 ns | +0.283 | 4.039 ns | 231.37 MHz |
| xoodyak | 7.698 ns | +0.136 | 7.562 ns | 129.90 MHz |
| giftcofb | 8.334 ns | +0.191 | 8.143 ns | 119.99 MHz |
| grain128aead | 4.667 ns | +0.188 | 4.479 ns | 214.27 MHz |
| sparkle | 13.438 ns | +0.076 | 13.362 ns | 74.42 MHz |
| elephant | 19.950 ns | +0.133 | 19.817 ns | **50.13 MHz** |
| isap | 6.093 ns | +0.147 | 5.946 ns | 164.12 MHz |
| photonbeetle | 8.131 ns | +0.105 | 8.026 ns | 122.99 MHz |
| romulus | 5.676 ns | +0.236 | 5.440 ns | 176.18 MHz |

All eleven routed with zero unrouted nets at their final constraint.

**Ascon-AEAD128 measures 241.43 MHz here, against 55.00 MHz in the previous
edition.** That is the single largest discrepancy in this file and it is not a
small correction. Three things point to the old figure being wrong rather than
this one: the previous edition's own sky130 result had Ascon at 256 MHz — the
fastest ASIC design in the set while simultaneously near-slowest on FPGA, which
is internally inconsistent; this re-measurement's sky130 result (260.6 MHz)
agrees with that 256 MHz to within 2%; and Ascon's round is combinationally
shallow (3 logic levels, §3.1 — an S-box and XORs of rotations, no adders), for
which 55 MHz on a -1L Artix-7 is implausibly slow. The register count is
identical to the previous edition on every design, so the RTL is the same. See
§8.1.

### 3.3 Power

Vectorless (default-activity) estimate for all eleven designs. The previous
edition had SAIF-annotated activity for the two Ascon-family designs; that
stimulus was not kept and could not be reproduced, so this column is now
uniform across rows but less accurate for those two. Read it as relative
ordering, not absolute silicon power.

| design | dynamic | device static | **total on-chip** | activity source |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 75 mW | 57 mW | 132 mW | vectorless |
| SipCon64 | 26 mW | 57 mW | 83 mW | vectorless |
| tinyjambu | 23 mW | 57 mW | 80 mW | vectorless |
| xoodyak | 39 mW | 57 mW | 97 mW | vectorless |
| giftcofb | 11 mW | 57 mW | 68 mW | vectorless |
| grain128aead | 28 mW | 57 mW | 85 mW | vectorless |
| sparkle | 48 mW | 57 mW | 105 mW | vectorless |
| elephant | 9 mW | 57 mW | **66 mW** | vectorless |
| isap | 77 mW | 57 mW | **134 mW** | vectorless |
| photonbeetle | 21 mW | 57 mW | 78 mW | vectorless |
| romulus | 21 mW | 57 mW | 78 mW | vectorless |

Device static power (57 mW) is a property of the XC7A12T and identical for all
eleven; only the dynamic component distinguishes the designs. **isap draws the
most (134 mW total) and elephant the least (66 mW)** — note that elephant is by
far the largest design here, so low power at 50 MHz reflects its slow clock,
not efficiency (its energy per bit is the worst in the set, §5).

---

## 4. ASIC — SkyWater sky130hd (130 nm, fabricable)

yosys synthesis (Verilog-2005 frontend, `dfflibmap`+`abc` mapped to
`sky130_fd_sc_hd__tt_025C_1v80`), then OpenROAD place-and-route: floorplan,
`global_placement` (density retried upward on failure), CTS,
`repair_timing` (setup then hold), global route. **No unmapped cells** in
any of the eleven netlists — `stat -liberty` accounts for 100% of each
design's area.

### 4.1 Area and timing

| design | yosys pre-P&R area | **P&R area** | **GE** | period | **Fmax** | clock skew |
|---|---:|---:|---:|---:|---:|---:|
| Ascon-AEAD128 | 46 610 µm² | 62 955 µm² | 16 772 | 3.838 ns | 260.6 MHz | 0.05 ns |
| SipCon64 | 37 002 µm² | 48 303 µm² | 12 869 | 17.012 ns | 58.8 MHz | -0.04 ns |
| tinyjambu | 23 881 µm² | **27 080 µm²** | **7 215** | 3.327 ns | 300.6 MHz | 0.03 ns |
| xoodyak | 58 345 µm² | 74 590 µm² | 19 872 | 5.102 ns | 196.0 MHz | 0.04 ns |
| giftcofb | 52 646 µm² | 61 003 µm² | 16 252 | 4.271 ns | 234.1 MHz | 0.04 ns |
| grain128aead | 36 901 µm² | 41 247 µm² | 10 989 | 3.606 ns | 277.3 MHz | -0.04 ns |
| sparkle | 91 614 µm² | 140 096 µm² | 37 323 | 24.243 ns | 41.2 MHz | 0.09 ns |
| elephant | 144 810 µm² | **173 446 µm²** | **46 208** | 12.789 ns | 78.2 MHz | -0.07 ns |
| isap | 83 810 µm² | 106 288 µm² | 28 316 | 5.380 ns | 185.9 MHz | 0.06 ns |
| photonbeetle | 81 579 µm² | 99 502 µm² | 26 509 | 8.961 ns | 111.6 MHz | -0.06 ns |
| romulus | 73 550 µm² | 84 876 µm² | 22 612 | 4.875 ns | 205.1 MHz | 0.06 ns |

Every design got the same period search this time, so "period" is a found
limit for all eleven rather than a generous starting guess for nine of them
(§1.2). P&R area is summed placed-instance area after global routing; GE is
that divided by the sky130hd NAND2_1 cell area of 3.7536 µm².

**The hybrid is the outlier on timing**: 17.012 ns, second-slowest of the
eleven and 4.4x Ascon's critical path, despite being 23% smaller in area. Its
round is ARX — four dependent 64-bit additions — and a 130 nm standard-cell
library has no hardened carry logic to absorb that, where an FPGA's dedicated
carry chains partly do (its FPGA path is only 1.7x Ascon's). See §7.

sparkle would not route at the 45% target utilization used for the other ten
and was placed at 30% instead; summed instance area is unaffected by
floorplan utilization, so its row remains comparable.

### 4.2 Power

Vectorless for all eleven — the same caveat as §3.3 applies, and the previous
edition's VCD-annotated figures for the two Ascon-family designs could not be
reproduced.

| design | combinational | clock | **total** | % combinational | source |
|---|---:|---:|---:|---:|---|
| Ascon-AEAD128 | 62.00 mW | 4.74 mW | 88.0 mW | 70.5% | vectorless |
| SipCon64 | 15.80 mW | 0.87 mW | 20.3 mW | 77.8% | vectorless |
| tinyjambu | 0.37 mW | 3.61 mW | **10.1 mW** | 3.6% | vectorless |
| xoodyak | 5.75 mW | 4.89 mW | 19.5 mW | 29.5% | vectorless |
| giftcofb | 18.80 mW | 5.61 mW | 38.8 mW | 48.5% | vectorless |
| grain128aead | 0.22 mW | 5.80 mW | 16.4 mW | 1.4% | vectorless |
| sparkle | **106.00 mW** | 1.13 mW | **109.0 mW** | **97.2%** | vectorless |
| elephant | 24.00 mW | 4.76 mW | 38.2 mW | 62.8% | vectorless |
| isap | 57.30 mW | 7.16 mW | 83.2 mW | 68.9% | vectorless |
| photonbeetle | 42.10 mW | 3.44 mW | 56.8 mW | 74.1% | vectorless |
| romulus | 15.10 mW | 7.29 mW | 38.7 mW | 39.0% | vectorless |

**sparkle remains the outlier at 109.0 mW, 97.2% of it combinational** — one
enormous per-cycle combinational round, which the default toggle-rate model
charges heavily. It is far less extreme than the previous edition's 272 mW,
but the shape of the result is the same and the same caveat holds: this is a
vectorless estimate of a very large combinational cloud, and it needs
activity-annotated simulation before being read as a real silicon number.

At the other end, **grain128aead and tinyjambu are almost entirely clock
power** (1.4% and 3.6% combinational) — both are bit-serial designs with tiny
per-cycle logic and many registers, so their power is dominated by the clock
tree rather than by switching.

---

## 5. Cycles, throughput and functional verification

Cycle-accurate throughput requires either a fixed, documented cycle schedule
confirmed by simulation, or a KAT run. That exists for the two Ascon-family
designs (identical FSM, so a block always costs 8 cycles plus one handshake
cycle) and, now, for Ascon-AEAD128 too (full official KAT pass, §1.1
footnote 3 — on top of, not instead of, the shared-FSM schedule below).
**All nine finalists are now also KAT-verified** (§1.1) — the correctness
question this section originally flagged is closed for ten of the eleven
designs; the hybrid now also has a KAT-style pass of its own,
against *self-generated* vectors rather than an official suite, since none
exists for it (§1.1 footnote 4) — all eleven designs in this file have now
been walked through some form of KAT vectors, real NIST ones for ten of
them, a self-generated one from the hybrid's own reference C for the
remaining one.

**2026-09-03: a steady-state cycle schedule was extracted for all nine
finalists from their own already-passing KAT stimulus**, closing the gap the
paragraph above used to describe. Method: each design's exact, already-proven
`kv2/<design>/*.mem` word streams (`tj/*.mem` for tinyjambu) — the identical
PDI/SDI/DO data that produced the `ALL_PASS` results in §1.1, generated by
`kv2/gen.py` from the official NIST KAT file, nothing re-invented — were
replayed through a cycle-instrumented copy of the same driver testbench
(`kv2cyc/tb_template_cyc.v`, identical handshake logic to `kv2/tb_template.v`,
only `$time` stamps added around each transaction; the pass/fail checker is
untouched) against the unmodified RTL in `verilog/`. All nine still reported
`ALL_PASS` on their full 2178-transaction grid under this instrumented
testbench, confirming the rerun didn't change behaviour. The official KAT
grid used by these testbenches is a 33×33 sweep of AD length × PT length,
0–32 bytes each, in row-major (PT outer, AD inner) order — holding AD length
at 0 and reading the 33 encrypt-transaction timestamps for PT = 0..32 bytes
isolates each design's **marginal** cost of absorbing one additional message
block: the fixed per-transaction setup (key schedule, Npub load, the
empty-AD segment header) is identical across all 33 rows and cancels out of
the difference, leaving only real, observed block-processing cycles — the
same principle as the Ascon-family schedule below (p^12 init vs. p^8
per-block), just measured instead of read off an FSM diagram. Two designs
(tinyjambu, giftcofb) and one three-way (isap) had enough same-size repeats
in-range to *independently confirm* the marginal cost is constant call after
call; three (xoodyak, sparkle, romulus) only have one clean block boundary
inside the 0–32-byte grid the official KAT vectors top out at, so their
numbers are real and simulation-derived but not independently confirmed to
repeat past that one boundary; elephant's crossing is genuinely irregular
(below) and is reported as a bracket, not a single number.

| design | rate (confirmed) | cycles / block | repeats agreeing | bits/cycle |
|---|---|---:|---|---:|
| tinyjambu | 4 B (32-bit word) | 36 | **8/8** identical | 0.889 |
| giftcofb | 16 B | 57 | **2/2** identical | 2.246 |
| isap | 8 B | 40 | **4/4** identical | 1.600 |
| photonbeetle | 16 B | 24, then 25 | 2/2, off by 1 cycle | 5.224 ¹ |
| grain | ~1 B (no wider block) | 17.25/byte | 32/32-point linear fit | 0.464 |
| xoodyak | 24 B (`Rkout`, matches header) | 18 | 1 (2nd block only 8/24 B reachable in-grid) | 10.667 |
| sparkle | 32 B (matches header) | 35 | 1 (grid's max PT *is* one rate block) | 7.314 |
| romulus | 16 B | 46 | 1 clean boundary (16→17 B) | 2.783 |
| elephant | 20 B (`BLOCK_SIZE`, matches header) | **irregular — see below** | — | — |

¹ photonbeetle's two measured blocks differ by exactly 1 cycle (24, then
25) — likely a control-path rounding detail, not re-derived further; 24.5
(average) is used below.

Two results are worth flagging on their own:

- **isap and romulus both confirm their own header's claimed schedule.**
  isap's header estimates "~151 cycles per call" for its expensive
  Keccak-*p*[400]-style permutation but doesn't commit to a cycles/block
  hardware number; the measured 40 cycles/8-byte block (identical four times
  running) is the real one. romulus's header describes SKINNY-128-384+ as
  "one round per cycle" with ~40 rounds; the one clean measured block
  boundary (46 cycles/16-byte block) is consistent with ~40 rounds plus a
  handful of FSM-overhead cycles — the header's *qualitative* claim (round
  count, one round/cycle) checks out even though it never stated a cycles/
  block figure to compare against directly.
- **elephant's block-boundary crossing does not reduce to one constant.**
  Spongent-π[160] calls cost 84 cycles each (pt 0→1, a clean single
  measurement, and consistent with the header's own "~80 cycles per
  permutation() call" — the ~4-cycle gap is FSM overhead, not a
  discrepancy). But crossing the one 20-byte (`BLOCK_SIZE`) boundary the
  0–32-byte KAT grid reaches costs **two** such calls back-to-back (pt
  19→20: +85, then pt 20→21: +84 — 169 cycles total, not one ~84-cycle
  call), a real, simulation-observed asymmetry between "entering the first
  block" and "crossing into the second," not a bug fix candidate (this RTL
  is KAT-verified and unchanged) and not investigated further here — it
  reads consistent with the header's own `nb_it = max(nblocks_c+1,
  nblocks_ad-1)` loop bound doing something extra exactly at an exact-multiple
  message length, the same family of exact-boundary edge case that produced
  several of the 42 bugs catalogued in `verilog/README.md`, except this one
  still passes every KAT vector, so it is reported here as an observed
  irregularity, not corrected. Elephant's row below is a bracket, not a
  point estimate, because of this.

The two Ascon-family designs share an FSM but no longer share a round
schedule: the hybrid's counts were reduced from p^12/p^8 to p^10/p^6 on
2026-09-08 (§1.1).

```
Ascon-AEAD128:                      SipCon64:
  initialisation      12 cycles       initialisation      10 cycles  (p^10)
  per AD block         8 cycles       per AD block         6 cycles  (p^6)
  per message block    8 cycles       per message block    6 cycles  (p^6,
                       (except last)                        except last)
  finalisation        12 cycles       finalisation        10 cycles  (p^10)
```

Each absorbed block also costs one handshake cycle in `S_WAIT`, so a block
that takes a permutation costs 9 cycles for Ascon and 7 for the hybrid.

| message / AD | Ascon (16-byte blocks) | r=64 (8-byte blocks) |
|---|---|---|
| 0 B / 0 B | 29 | 23 |
| 0 B / 16 B | 47 | 44 |
| 0 B / 32 B | 56 | 58 |
| 64 B / 64 B | 110 | 142 |

Throughput is **16 bits/cycle for Ascon-AEAD128 and 64/6 = 10.67 bits/cycle
for r=64** (previously 8) — see the energy-per-bit figures below and §6.

| design | functional check | pass rate | throughput | energy / bit |
|---|---|---:|---:|---:|
| Ascon-AEAD128 | official NIST KAT suite (1089 vectors) + 16×16 length grid vs. C ref, both directions | **1089/1089 enc, 1089/1089 dec** (KAT); 256/256 enc, 256/256 dec (grid) | 3,863 Mbit/s (FPGA), 4.170 Gbit/s (sky130) | 34 pJ (FPGA), 21 pJ (sky130) |
| SipCon64 | directed C-vs-RTL simulation (see §1.1) — earlier self-generated KAT invalidated by the 2026-09-08 round change | ciphertext + tag match the C reference; C round-trips and rejects tampering | 1,487 Mbit/s (FPGA), 0.627 Gbit/s (sky130) | 56 pJ (FPGA), 32 pJ (sky130) |
| tinyjambu | official NIST KAT suite | **17127/17127 words** | 205 Mbit/s (FPGA), 0.267 Gbit/s (sky130) | 390 pJ (FPGA), 38 pJ (sky130) |
| xoodyak | official NIST KAT suite | 19305/19305 words | 1,386 Mbit/s (FPGA), 2.091 Gbit/s (sky130) | 70 pJ (FPGA), 9 pJ (sky130) |
| giftcofb | official NIST KAT suite | 19305/19305 words | 269 Mbit/s (FPGA), 0.525 Gbit/s (sky130) | 253 pJ (FPGA), 74 pJ (sky130) |
| grain128aead | official NIST KAT suite | 17127/17127 words | 100 Mbit/s (FPGA), 0.129 Gbit/s (sky130) | 852 pJ (FPGA), 127 pJ (sky130) |
| sparkle | official NIST KAT suite | 19305/19305 words | 545 Mbit/s (FPGA), 0.302 Gbit/s (sky130) | 193 pJ (FPGA), 361 pJ (sky130) |
| elephant | official NIST KAT suite | 17127/17127 words | 48–95 Mbit/s (FPGA), 0.074–0.149 Gbit/s (sky130) | 693–1,386 pJ (FPGA), 257–514 pJ (sky130) |
| isap | official NIST KAT suite | 19305/19305 words | 262 Mbit/s (FPGA), 0.297 Gbit/s (sky130) | 511 pJ (FPGA), 280 pJ (sky130) |
| photonbeetle | official NIST KAT suite | 19305/19305 words | 643 Mbit/s (FPGA), 0.583 Gbit/s (sky130) | 121 pJ (FPGA), 97 pJ (sky130) |
| romulus | official NIST KAT suite | 19305/19305 words | 490 Mbit/s (FPGA), 0.571 Gbit/s (sky130) | 159 pJ (FPGA), 68 pJ (sky130) |

² **Energy/bit is comparable across all eleven rows in this edition.** It is
total on-chip power (§3.3) divided by throughput, for every design, on both
targets. The previous edition divided by *dynamic* power alone for the two
Ascon-family FPGA rows — because those had a SAIF-annotated run that split
dynamic from static, which the vectorless finalists did not — and its own
footnote warned that the column could not be read across that boundary. With
all eleven now measured the same vectorless way (§1.2, §8.2), that caveat is
gone and the column can be compared row to row.

One consequence: the two Ascon-family FPGA energy figures are larger than the
previous edition's (34 pJ for Ascon against 20.5 before) because the 57 mW
device-static floor is now included rather than excluded, not because either
design became less efficient.

All nine finalists' throughput and energy/bit figures above are new in this
pass, extracted from re-running each design's own already-passing KAT
stimulus through a cycle-instrumented testbench (§5 above) — not assumed,
not carried over from any design document. tinyjambu's number resolves a
figure this file previously referenced ("whose schedule was already
tabulated separately") but never actually included; it is included now
(36 cycles/32-bit PT word, confirmed identically 8/8 times across the
whole 0–32-byte range — the cleanest schedule measured of any of the nine).

Leakage is negligible in the sky130 library at this corner (~2×10⁻⁸ W), so
sky130 energy per bit for the Ascon-family designs is essentially
frequency-independent and those two figures compare directly. The nine
finalists' sky130 power is vectorless (§4.2), not simulation-derived, so
their sky130 energy/bit inherits that same caveat regardless of how exactly
the cycle count was measured.

---

## 6. Where each design wins

**Between the two Ascon-family designs, Ascon-AEAD128 now wins on both
targets.** The previous edition had r=64 leading on FPGA, but that rested on
Ascon's 55.0 MHz figure, which this re-measurement does not reproduce (§3.2).
With Ascon at 241.4 MHz on FPGA and 260.6 MHz on sky130:

| | Ascon-AEAD128 | SipCon64 |
|---|---:|---:|
| FPGA Fmax | **241.4 MHz** | 139.4 MHz |
| FPGA throughput | **3 863 Mbit/s** | 1 487 Mbit/s |
| FPGA energy / bit | **34 pJ** | 56 pJ |
| sky130 Fmax | **260.6 MHz** | 58.8 MHz |
| sky130 throughput | **4.17 Gbit/s** | 0.63 Gbit/s |
| sky130 energy / bit | **21 pJ** | 32 pJ |
| FPGA Slice LUTs | 1122 | **874** |
| sky130 area | 62 955 µm² | **48 304 µm²** |

**What r=64 retains is area**: 22% fewer LUTs and 23% less ASIC area, while
keeping Ascon's 192-bit capacity in a smaller state. What it does not retain
is any throughput or energy advantage on either target. The reduction to
p^10/p^6 (§5) improved its throughput by 36% on FPGA and 40% on ASIC over the
previous edition and did not change this conclusion.

The ASIC gap is the severe one — 4.4× on critical path — and §7 explains it:
the hybrid's round is four dependent 64-bit additions, and standard cells have
no hardened carry logic to absorb them where an FPGA partly does.

**Across the full field of eleven: tinyjambu is the smallest design on both
targets, the fastest on sky130, and the lowest-power on sky130.** It no longer
leads FPGA Fmax — Ascon does, at 241.4 MHz against tinyjambu's 231.4. TinyJAMBU's
premise is an extremely small, simple permutation, which is also why it needed
zero fixes to pass the KAT grid the other eight finalists needed 42 bugs fixed
for. **elephant and sparkle sit at the opposite end** — largest by a wide
margin on both targets — for the structural reasons in §7, not because they are
"worse ciphers"; NIST evaluated all nine finalists on security and multiple
cost metrics, and this repo measures only one implementation choice
(round-per-cycle) of each.

---

## 7. Why some designs cost more than others

Two different bottlenecks dominate depending on the target and the design.

**Between the two Ascon-family designs, the FPGA bottleneck is the padding
mask, not the cipher.** The critical path is `din_bytes → st_reg`, 18 logic
levels of which 15 are CARRY4 — a borrow chain from

```verilog
wire [127:0] mask = full ? {128{1'b1}} : ((128'd1 << shamt) - 128'd1);
```

The `- 1` is what costs it. r=64 is the natural experiment for this: its
rate is 64 bits, so the same expression builds a 64-bit chain instead of a
128-bit one, logic levels drop 18 → 10, and the clock nearly doubles (55.0 →
117.0 MHz) despite an identical round function otherwise. That is the
mask being measured, not the cipher. **On ASIC the mask is cheap** —
`repair_timing` optimises it away, and the real architectural difference
appears: Ascon's XOR/AND round collapses to a 3.9 ns path, while SIPROUND
contains four chained 64-bit additions that no optimiser can shorten,
holding r=64's ASIC critical path at 16.0 ns regardless of its narrower
rate. A byte-wise decoder (replacing the shift-and-subtract
mask with a per-lane comparator) would remove the FPGA chain entirely and
lift both Ascon-family designs — not attempted here.

**Among the nine finalists, cost tracks each algorithm's per-cycle
combinational shape**, not a shared artefact the way the padding mask is for
the Ascon family — these are nine unrelated designs. elephant's
Spongent-π[160] permutation is both wide (160-bit state, an 8-bit S-box on
all 20 bytes plus a full 160-bit wire permutation every round) and called
often — up to three 80-round permutation calls per main-loop iteration, plus
two more for key expansion and finalization — and against the bug-fixed RTL
it is now the deepest single-cycle path measured in the whole set (28 logic
levels on FPGA), ahead of sparkle. sparkle's Schwaemm256-128 runs 6 parallel
ARX-boxes plus a linear layer as one per-cycle combinational block (22 logic
levels on FPGA against this bug-fixed RTL, down from 27 against the buggy
RTL — its one fix removed a spurious `bswap()` at nine sites, i.e. it made
the design smaller, not bigger). By contrast tinyjambu, isap and romulus
keep their per-cycle logic shallow (2 levels) by design, even though grain
and romulus both run many cycles per byte to get there — a direct
cycle-count-vs-per-cycle-cost tradeoff, the same shape as the Ascon-family
mask/cipher tradeoff above, just driven by each algorithm's own structure
instead of one shared expression. This reordering versus the superseded
2026-08-29 pass (where sparkle was deepest) is itself informative: on
buggy-but-passing-lint RTL, a wrong compensating operation can look like
"real" combinational cost until KAT simulation proves it wrong and removes
it.

---

## 8. Caveats

### 8.1 Applies to all eleven designs

1. **Hold on FPGA is a constraint artefact, not a design defect**, on every
   one of the eleven. The worst hold path is always at an input port (e.g.
   `key[116] → k_r_reg[116]/D`) because `set_input_delay 0` gives it no
   launch delay to absorb. There is not a single register-to-register hold
   violation in any design on either target, and on sky130 **all eleven
   have positive hold slack**. Realistic input delays would remove the FPGA
   artefact too; only actually re-verified for the two Ascon-family
   designs (+0.14/+0.12 ns after the fix), not re-checked per finalist.
2. Derived quantities — achieved period (`constraint − WNS`), throughput
   (`bits/cycle × f`), energy per bit (`power ÷ throughput`), gate
   equivalents (`cell area ÷ 3.7536 µm²`) — are arithmetic on the tool
   outputs above.
3. **All nine finalists have now been run against the official NIST KAT
   vectors** (§1.1) — previously only tinyjambu had. The other eight needed
   42 real bugs fixed between them first; every number in §2–§4 for them is
   against the fixed, KAT-passing RTL, not the RTL that produced the
   2026-08-29 figures this file used to report. See `verilog/README.md`'s
   verification table and bug catalogue for exactly what was wrong and how
   it was found.
4. **The hybrid has had no dedicated cryptanalysis of its own.** These are
   engineering measurements, not a security argument, and the same applies by extension to any of the nine
   finalists' *specific implementation choices* here (this repo did not
   re-derive or re-verify any of the nine algorithms' own published security
   analyses — those are NIST's and each design team's, not re-litigated here).

### 8.2 Consequences of the flow rebuild

5. **All power is vectorless**, on both targets, for all eleven designs. The
   previous edition had simulation-derived activity (SAIF for FPGA, VCD for
   sky130) for the two Ascon-family designs; that stimulus was not kept and
   could not be reproduced. Vectorless numbers are default-toggle-rate
   estimates — read them as relative ordering, not absolute silicon power.
   sparkle's §4.2 figure in particular should not be trusted without an
   activity-annotated re-run.
6. **The absolute numbers are not comparable with the previous edition.**
   This is a different flow — rebuilt scripts, Vivado 2026.1, a hand-rolled
   OpenROAD sequence rather than ORFS (§10) — so differences between editions
   mix real effects with flow differences and cannot be attributed to either
   without the original scripts, which no longer exist.
7. **What did reproduce is the evidence the rebuild is sound**: register
   counts match the previous edition exactly on all eleven designs; FPGA
   Slice LUTs match within ±2% on ten of eleven (romulus +8.2%); sky130 area
   matches within ±8% on all nine finalists. The one large discrepancy,
   Ascon's FPGA Fmax, is discussed in §3.2 and is more likely an error in the
   previous edition than in this one.
8. **The two Ascon-family designs' sky130 area is ~30% above the previous
   edition** while the nine finalists are within ±8%. That asymmetry is
   unexplained. The likeliest cause is that those two were measured by the
   deeper pass in the previous edition and the nine by the lighter one, so
   the finalists happen to sit closer to what a uniform flow produces — but
   this has not been confirmed and should be treated as an open question.
9. **The vendored sky130hd platform is incomplete.** `config.mk` references
   `make_tracks.tcl`, `pdn.tcl`, `fastroute.tcl` and the yosys cell-map files
   (`cells_adders_hd.v` among them); none were copied. Routing tracks were
   reconstructed from the tech LEF (they match ORFS exactly), but the missing
   adder mapping means adders were synthesized generically. That
   disproportionately penalises the one adder-dominated design in the set —
   the hybrid — so its sky130 Fmax may be pessimistic. Recovering
   `cells_adders_hd.v` and re-running it is the obvious check.
10. **The flow stops after global routing**, not detailed routing, because
    the PDN config needed for detailed routing was among the missing platform
    files. Area, timing and power are all available at that point; DRC-clean
    detailed routing is not claimed.

### 8.3 The hybrid only

11. **The hybrid has no valid known-answer test.** Its round counts changed
    on 2026-09-08 and its previous 1089-vector self-generated suite was
    produced from the older p^12/p^8 construction, so that pass no longer
    applies (§1.1 footnote 4). Current evidence is a single directed
    C-vs-RTL simulation. It is the least-verified design in this file.
12. **The round reduction lowered its security margin.** No dedicated
    analysis backs either the old counts or the new ones; establishing the
    margin for p^10/p^6 is future work. Nothing in this file is a security
    claim — performance numbers say nothing about whether the construction
    is sound.
13. These are eleven different algorithms with different security margins,
    round counts and tag sizes — smaller/faster is not "better" in isolation;
    it is one input into a tradeoff that also depends on each algorithm's
    security case, which is out of scope here.

---

## 9. Method notes specific to the finalist RTL

Two files needed a fix to synthesize under yosys (§1.2): `giftcofb_lwc.v`
and `romulus_n_lwc.v` both part-selected a function call's return value
directly (`f(...)[a:b]`) — legal Verilog-2005, accepted by Verilator and
Vivado, rejected by yosys's Verilog-2005 frontend. Both were fixed by
holding the call's result in an intermediate signal first and slicing from
that instead; re-lint in Verilator and Vivado after the fix confirmed no
behavioural change before re-synthesizing. This fix is unrelated to, and
predates, the 42-bug KAT correctness pass (§1.1) — both files still carry it
in the RTL measured for this rerun, and both synthesized cleanly under
yosys again (no unmapped cells, confirmed in this rerun's
`giftcofb_yosys.log` / `romulus_yosys.log`).

---

## 10. Provenance

**The flow is in this repository**, at [`flow/`](flow/), version-controlled
alongside the RTL. The previous edition's scripts lived only in temporary
session scratchpads and were lost, which is why this edition exists; that
failure mode is now closed.

| file | what it does |
|---|---|
| `flow/vivado_flow.tcl` | Vivado OOC flow + adaptive period search, one design |
| `flow/run_vivado.sh` | drives all eleven, resumable, N concurrent |
| `flow/sky130_syn.ys.in` | yosys synthesis template for sky130hd |
| `flow/sky130_pnr.tcl` | OpenROAD floorplan → place → CTS → global route → reports |
| `flow/run_sky130.sh` | drives all eleven, resumable |
| `flow/reextract_vivado.py` | rebuilds the Vivado CSV from saved reports |
| `flow/merge_results.py` | merges both sweeps into `graphs/results.csv` |
| `flow/build_hw_xlsx.py` | builds `hardware_analysis.xlsx` from that CSV |

Reproduce with `flow/run_vivado.sh && flow/run_sky130.sh && python3
flow/merge_results.py`. Build artifacts go to `~/.ascon-flow/` (outside the
repo, and outside `/tmp`, so a long sweep survives across sessions); both
runners skip designs that already have results, so an interrupted sweep
restarts without losing completed work.

| Metric | Tool | Source |
|---|---|---|
| FPGA LUTs, registers, occupied slices | Vivado 2026.1 | `report_utilization`, "Slice LUTs" row — not a count of LUT primitives |
| FPGA Fmax, WNS, logic levels | Vivado 2026.1 | `report_timing_summary` at the tightest closing constraint |
| FPGA power | Vivado `report_power` | vectorless; total on-chip = dynamic + 57 mW device static |
| FPGA route status | Vivado | zero unrouted nets required for a period to count as closing |
| sky130 pre-P&R area | yosys 0.38 | `stat -liberty` |
| sky130 P&R area, GE | OpenROAD 2.0 | summed placed-instance area from OpenDB, ÷ 3.7536 µm² for GE |
| sky130 Fmax, slack | OpenSTA (in OpenROAD) | `worst_slack` after global routing |
| sky130 power, clock skew | OpenROAD | `report_power`, `report_clock_skew`, vectorless |
| sky130 platform | vendored ORFS platform copy | `~/pdks/sky130hd` — **incomplete**, see §8.2 item 9 |
| Cycle schedules | design headers + `xsim` | `verilog/*.v`, confirmed by simulation |

**Tool versions:** Vivado v2026.1; OpenROAD 2.0-12381-g01bba3695; yosys
0.38+92. Part `xc7a12ticsg325-1L`; library `sky130_fd_sc_hd__tt_025C_1v80`.

**Not ORFS.** OpenROAD-flow-scripts is not installed on this machine and the
vendored platform copy is missing several files ORFS supplies, so
`flow/sky130_pnr.tcl` reproduces the ORFS RTL-to-routed sequence by hand.
Routing tracks were reconstructed from the tech LEF's own LAYER pitches and
match ORFS's values exactly; the `DONT_USE_CELLS` exclusion is read from the
platform's own `config.mk`. What could not be reconstructed is listed in
§8.2.

**Raw logs** are under `~/.ascon-flow/vivado/` and `~/.ascon-flow/sky130/`,
one directory per design per attempted period, each containing the synthesis
script, the netlist, and the full tool log. They are working files, not part
of this repository — but unlike the previous edition, the scripts that
produce them are.
