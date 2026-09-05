# Hardware results: Ascon-AEAD128, two Ascon-SipHash hybrids, and the 9 NIST LWC finalists

Area, timing and power for all twelve AEAD cores in [`verilog/`](verilog/) —
the NIST-standardized Ascon-AEAD128, two experimental Ascon-SipHash hybrids,
and one core per algorithm that lost to Ascon in the final round of NIST's
Lightweight Cryptography competition — measured on the same FPGA with Vivado
and the same 130 nm ASIC process with OpenROAD.

**Every number was produced by Xilinx Vivado or by OpenROAD** on this
machine. Section 10 maps each metric to the log it came from. The three
Ascon-family designs were measured 2026-08-25 and are unchanged since (their
RTL was not touched by the bug-fixing pass below); the nine finalists were
originally measured 2026-08-29, but that RTL had 42 real correctness bugs in
it, found and fixed via full-grid KAT simulation between 2026-08-31 and
2026-09-02 (see `verilog/README.md`). **The finalist FPGA and sky130 numbers
below are a full rerun against that fixed RTL, done 2026-09-02** — the
2026-08-29 figures are superseded and no longer appear in this file. See
§1.2 for what differs between the Ascon-family and finalist measurement
passes and why some columns below carry a footnote. `ascon_aead128.v` was
additionally run, 2026-09-02, against the official NIST-format KAT vector
suite for Ascon-AEAD128 (§1.1, §5); the RTL measured throughout this file is
unchanged by that run.

---

## 1. Designs, tools and targets

### 1.1 The twelve designs

| design | file | key / npub / tag (bytes) | KAT-verified? |
|---|---|---|---|
| **Ascon-AEAD128** (the winner) | `ascon_aead128.v` | 16 / 16 / 16 | **yes** (1089/1089 vectors)³ |
| **hybrid r=128** (unanalysed) | `asconsip_aead.v` | 16 / 16 / 16 | **yes**, self-generated (1089/1089 vectors)⁴ |
| **hybrid r=64** (unanalysed) | `asconsip64_aead.v` | 16 / 16 / 16 | **yes**, self-generated (1089/1089 vectors)⁴ |
| TinyJAMBU-128 | `tinyjambu_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words) |
| Xoodyak | `xoodyak_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 6 bugs² |
| GIFT-COFB | `giftcofb_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 9 bugs² |
| Grain-128AEAD | `grain128aead_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words), after fixing 5 bugs² |
| SPARKLE (Schwaemm256-128) | `sparkle_lwc.v` | 16 / 32 / 16 | **yes** (19305/19305 words), after fixing 1 bug² |
| Elephant (Dumbo) | `elephant_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words), after fixing 5 bugs² |
| ISAP (ISAP-A-128A) | `isap_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 4 bugs² |
| PHOTON-Beetle | `photonbeetle_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 9 bugs² |
| Romulus (Romulus-N) | `romulus_n_lwc.v` | 16 / 16 / 16 | **yes** (19305/19305 words), after fixing 3 bugs² |

¹ Also verified against the C reference via Vivado `xsim` (a 16×16
synthetic grid of message/AD lengths, both directions — §5), independently
of the KAT run in footnote 4 below. Unlike Ascon-AEAD128, neither hybrid is
a NIST submission, so no *official* KAT vector suite exists for either —
see `verilog/README.md` and `ascon-siphash/README.md` for what was actually
checked and why, and footnote 4 for the self-generated KAT-style vectors
that were run in addition to this grid.

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

⁴ No official NIST KAT suite exists for either hybrid (footnote 1) — but the
same generation method NIST used to produce Ascon-AEAD128's own suite
(footnote 3) can be pointed at a different reference implementation: NIST's
own unmodified KAT generator, `genkat_aead.c` (vendored in the `ascon-c`
tree, the same file used unchanged for footnote 3), was re-linked against
each hybrid's own reference C — `ascon-siphash/asconsip.c` for r=128,
`ascon-siphash/asconsip64.c` for r=64 — via a small `api.h` (16/16/16
key/npub/tag, per the table above) and a `crypto_aead.h` shim that redirects
the generator's calls to `asconsip_aead_encrypt`/`_decrypt` or
`asconsip64_aead_encrypt`/`_decrypt`. This produced two real, independently
computed KAT files (1089 Count/Key/Nonce/PT/AD/CT vectors each, same format
as `LWC_AEAD_KAT_128_128.txt`), whose answers come from each hybrid's own
correct reference implementation — not from Ascon's, and not copied from
anywhere; the two hybrids' CT values differ from each other and from
Ascon-AEAD128's own KAT file on every non-trivial vector, as expected for
three different constructions. A testbench adapted from
`kat_ascon/tb_ascon_kat.v` (same custom block interface both hybrids share
with `ascon_aead128.v`, r=64 adjusted only for its 8-byte block/64-bit `din`
in place of 16-byte/128-bit) walked both files through
`asconsip_aead.v`/`asconsip64_aead.v` in Vivado `xsim`, both directions,
2026-09-04, against the same unmodified RTL measured throughout this file:
**1089/1089 encrypt, 1089/1089 decrypt for r=128; 1089/1089 encrypt,
1089/1089 decrypt for r=64**. This is a real KAT-style run with real,
independently generated vectors — a materially stronger check than the
16×16 grid in footnote 1 — but it is **not** the official NIST suite
Ascon-AEAD128 gets in footnote 3: NIST never received these constructions,
so there is no NIST-published answer key to check against, only each
hybrid's own reference C, which is the same reference the 16×16 grid in
footnote 1 already checked against. Read this result as "self-consistent
across two independent implementations of each hybrid's own construction
over a much larger vector set," not as "passes NIST's test suite" — see
`verilog/README.md` for the same distinction spelled out at more length.

The first three implement a **custom** block-oriented interface; the other
nine implement the **NIST LWC Hardware API** (PDI/SDI/DO). They are not
port-compatible — see `verilog/README.md`. That does not stop them being
measured, and compared, the same way: this file treats all twelve as one
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

The three Ascon-family designs got a deeper first pass than the nine
finalists; the gap is visible below as footnotes, not hidden:

| | Ascon + 2 hybrids | 9 finalists |
|---|---|---|
| Vivado period search | up to 7 iterations, hand-seeded | 3 iterations, generic starting period |
| sky130 period | swept per design to its limit | one fixed, generous period per design |
| FPGA power | vectorless **and** SAIF from RTL simulation | vectorless only |
| sky130 power | vectorless **and** VCD-annotated | vectorless only |
| Gate-level simulation | attempted (sky130 cell models) | not attempted |

So sky130 Fmax for the nine finalists is a **lower bound** — whatever slack
was left over at a period guessed generous enough to close first try, not a
searched minimum — while the three Ascon-family figures are close to each
design's real ceiling. Power for the nine is a default-activity estimate,
not simulation-derived; §4.2 shows why that matters most for sparkle.

Two finalist files needed an RTL fix to reach this data: `giftcofb_lwc.v`
and `romulus_n_lwc.v` both part-selected a function call's return value
directly (`f(...)[a:b]`) — legal Verilog-2005, accepted by Verilator and
Vivado, rejected by yosys's parser. Both were fixed by holding the call's
result in an intermediate signal first; re-lint in Verilator and Vivado
confirmed no behavioural change. That fix predates and is independent of the
42-bug correctness pass in §1.1 above; this rerun's yosys logs confirm both
still synthesize cleanly (no unmapped cells) with it in place.

**The nine finalists' FPGA and sky130 numbers in §2–§4 below are a full
rerun**, done 2026-09-02 against the RTL as fixed for §1.1, using the exact
same scripts and search depth as the superseded 2026-08-29 pass (3-iteration
Vivado period search from the same generic starting periods; one fixed
sky130 period per design). The three Ascon-family designs' numbers are
untouched — that RTL did not change, so the 2026-08-25 figures still stand
and were not re-run.

---

## 2. Headline

All twelve, sorted by sky130 area (smallest first). GE = gate equivalents =
cell area ÷ sky130 NAND2 area (3.7536 µm²). **†** = simulation-derived
activity (SAIF/VCD); no mark = vectorless default-activity estimate — see
§1.2 before comparing power across the † boundary.

| design | FPGA LUTs | FPGA regs | FPGA Fmax | FPGA power | sky130 area | sky130 GE | sky130 Fmax | sky130 power |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **tinyjambu** | 472 | 533 | 214.1 MHz | 76.0 mW | **26 514 µm²** | **7 064** | 257 MHz | **3.07 mW** |
| **hybrid r=64** | 873 | 599 | **117.0 MHz** | 76 mW † | 36 895 µm² | 9 829 | 62.5 MHz | 23.7 mW † |
| grain | 587 | 915 | 172.6 MHz | 78.0 mW | 39 196 µm² | 10 442 | 232 MHz | 4.51 mW |
| **hybrid r=128** | 1021 | 663 | 54.4 MHz | 68 mW † | 41 044 µm² | 10 935 | 62.5 MHz | 25.0 mW † |
| **Ascon-AEAD128** | 1101 | 728 | 55.0 MHz | 75 mW † | 46 605 µm² | 12 416 | **256 MHz** | 88.7 mW † |
| giftcofb | 1531 | 1005 | 126.4 MHz | 68.0 mW | 59 856 µm² | 15 946 | 185 MHz | 5.32 mW |
| xoodyak | 1555 | 885 | 133.2 MHz | 97.0 mW | 68 960 µm² | 18 372 | 225 MHz | 4.48 mW |
| romulus | 1385 | 1430 | 138.6 MHz | 72.0 mW | 85 117 µm² | 22 676 | 198 MHz | 7.02 mW |
| photonbeetle | 2031 | 1090 | 113.7 MHz | 76.0 mW | 98 765 µm² | 26 312 | 119 MHz | 16.88 mW |
| isap | 2347 | 1651 | 145.6 MHz | 115.0 mW | 104 757 µm² | 27 908 | 197 MHz | 27.21 mW |
| sparkle | 2352 | 1093 | 66.1 MHz | 98.0 mW | 132 133 µm² | 35 202 | 40 MHz | 272.21 mW ² |
| **elephant** | **4621** | **2472** | **45.0 MHz** | 64.0 mW | **169 458 µm²** | **45 145** | 60 MHz | 12.21 mW |

² sparkle's vectorless power is far above every other design (98% of it
combinational) — see §4.2; likely a default-activity artifact of its single
huge per-cycle combinational round, not necessarily a real number.

**tinyjambu is the smallest and fastest design in the entire set** — smaller
and faster than Ascon-AEAD128 itself on FPGA, though not on sky130 where
Ascon's tighter, fully-swept critical path (256 MHz) edges out tinyjambu's
single-point estimate (257 MHz, likely understated per §1.2). That is not a
contradiction: tinyjambu has an 8-byte tag against Ascon's 16 and fewer
permutation rounds per block. Unlike the previous version of this table, all
nine finalists are now KAT-verified (§1.1) — "smallest measured" is now also
"smallest of the verified," not a caveat about unconfirmed RTL.
**elephant and sparkle are the two heavyweights** in this set, each for a
different structural reason — see §7. Among the three Ascon-family designs,
**r=64 is the best FPGA design and Ascon is the best ASIC design**; neither
wins everywhere — see §6.

All nine finalists' numbers above changed from the previous version of this
file (some up, some down — fixing 42 correctness bugs adds and removes
logic in ways that don't move area or timing in one direction) because they
are measured against the bug-fixed RTL; the three Ascon-family rows are
character-for-character the same figures as before because that RTL did not
change. tinyjambu's own row is numerically identical to the prior pass too,
for the same reason: `tinyjambu_lwc.v` needed none of the 42 fixes.

---

## 3. FPGA — Vivado, xc7a12ticsg325-1L

Out-of-context synthesis (`synth_design -mode out_of_context`), then
`opt_design → place_design → phys_opt_design → route_design`,
single-threaded so results are reproducible. All twelve **routed with zero
errors** at their final constraint.

Out-of-context is the standard way to characterise an IP core and is how
published Ascon figures are measured. It is also the only option here: these
cores have far more ports than CSG325 offers usable I/O, so an I/O-buffered
build is not physically possible. Frequencies are for the core alone and
would fall once integrated behind real I/O paths.

### 3.1 Resources

| design | Slice LUTs | Slice Registers | Occupied slices | logic levels |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 1101 (13.8%) | 728 | 355 | 18 |
| hybrid r=128 | 1021 (12.8%) | 663 | 323 | 18 |
| hybrid r=64 | 873 (10.9%) | 599 | 271 | 10 |
| tinyjambu | 472 (5.9%) | 533 | — | 2 |
| xoodyak | 1555 (19.4%) | 885 | — | 7 |
| giftcofb | 1531 (19.1%) | 1005 | — | 13 |
| grain | 587 (7.3%) | 915 | — | 4 |
| sparkle | 2352 (29.4%) | 1093 | — | 22 |
| elephant | **4621 (57.8%)** | **2472** | — | **28** |
| isap | 2347 (29.3%) | 1651 | — | 2 |
| photonbeetle | 2031 (25.4%) | 1090 | — | 8 |
| romulus | 1385 (17.3%) | 1430 | — | 2 |

(Occupied-slice figures were only recorded for the three Ascon-family
designs' first, deeper pass — §1.2; the rest were not re-extracted for the
lighter finalist pass, so those cells are left blank rather than guessed.)

Logic-level count tracks each algorithm's per-cycle combinational shape more
than its cycle count, and for the nine finalists these numbers moved from
the previous (buggy-RTL) pass in both directions — fixing a bug can add
logic (a missing byte-swap or key-schedule reset that now actually exists)
or remove it (a wrong compensating operation, like sparkle's incorrect
`bswap()`, deleted outright) or leave the achieved critical path essentially
unchanged even as area moves. **elephant now has the deepest single FPGA
path in the whole set (28 levels)**, edging out sparkle (22, down from 27 —
consistent with a real correctness fix removing logic rather than adding
it) — elephant's Spongent-π[160] permutation is both wide (160-bit state, an
8-bit S-box on all 20 bytes plus a full 160-bit wire permutation every
round) and, after its own 5 bug fixes, now the deepest path measured here.
tinyjambu, isap and romulus keep their per-cycle logic shallowest (2 levels)
even though grain and romulus run many cycles per byte. Ascon and hybrid
r=128 both sit at 18 levels for a different reason — §7: the same 128-bit
padding-mask borrow chain, not their round functions.

### 3.2 Timing

QoR is **non-monotonic in the constraint** even when deterministic: a
tighter constraint can route better than a looser one, so Fmax below is the
best achieved period across a search (§1.2 — 7 iterations for the three
Ascon-family designs, 3 for the nine finalists), not a single point.

| design | tightest closing constraint | WNS | achieved period | **Fmax** |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 18.384 ns | +0.202 | 18.182 ns | 55.00 MHz |
| hybrid r=128 | 18.960 ns | +0.560 | 18.400 ns | 54.35 MHz |
| hybrid r=64 | 8.719 ns | +0.174 | 8.545 ns | 117.03 MHz |
| tinyjambu | 5.169 ns | +0.499 | 4.670 ns | **214.13 MHz** |
| xoodyak | 7.747 ns | +0.242 | 7.505 ns | 133.24 MHz |
| giftcofb | 8.470 ns | +0.558 | 7.912 ns | 126.39 MHz |
| grain | 6.267 ns | +0.472 | 5.795 ns | 172.56 MHz |
| sparkle | 15.343 ns | +0.220 | 15.123 ns | 66.12 MHz |
| elephant | 22.795 ns | +0.578 | 22.217 ns | **45.01 MHz** |
| isap | 7.949 ns | +1.082 | 6.867 ns | 145.62 MHz |
| photonbeetle | 9.057 ns | +0.265 | 8.792 ns | 113.74 MHz |
| romulus | 8.144 ns | +0.931 | 7.213 ns | 138.64 MHz |

Every design shows the **same WHS = −0.502 ns** hold violation (sparkle
alone at −0.441 ns), always at an input port (e.g. `key[116] →
k_r_reg[116]/D`), because `set_input_delay 0` gives it no launch delay to
absorb. There is not a single register-to-register hold violation in any of
the twelve designs on either target — see the caveat in §8.1 for why this is
a constraint artefact, not twelve independent design defects. The nine
finalist rows above are a fresh 3-iteration period search against the
bug-fixed RTL (§1.2); all nine still routed with zero errors at their final
constraint, same as the superseded pass.

### 3.3 Power

| design | dynamic | static / clock | **total on-chip** | activity source |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 18 mW | 57 mW | 75 mW | SAIF, period-matched † |
| hybrid r=128 | 11 mW | 57 mW | 68 mW | SAIF, period-matched † |
| hybrid r=64 | 19 mW | 57 mW | 76 mW | SAIF, period-matched † |
| tinyjambu | — | — | 76.0 mW | vectorless |
| xoodyak | — | — | 97.0 mW | vectorless |
| giftcofb | — | — | 68.0 mW | vectorless |
| grain | — | — | 78.0 mW | vectorless |
| sparkle | — | — | 98.0 mW | vectorless |
| elephant | — | — | 64.0 mW | vectorless |
| isap | — | — | 115.0 mW | vectorless |
| photonbeetle | — | — | 76.0 mW | vectorless |
| romulus | — | — | 72.0 mW | vectorless |

Static power (57 mW) is a device property of the XC7A12T and applies to all
twelve equally; it was only broken out from dynamic power for the three
Ascon-family designs' SAIF-annotated run. The finalists' vectorless total is
not split into dynamic/static components by `report_power` the way the
SAIF-annotated run is, so those columns are left blank rather than guessed.
Vectorless FPGA power sits in a much narrower band (64–115 mW) than the
sky130 vectorless numbers do (§4.2) — Vivado's default activity model is
evidently less sensitive to a design's combinational-logic size than
OpenROAD's.

---

## 4. ASIC — SkyWater sky130hd (130 nm, fabricable)

yosys synthesis (Verilog-2005 frontend, `dfflibmap`+`abc` mapped to
`sky130_fd_sc_hd__tt_025C_1v80`), then OpenROAD place-and-route: floorplan,
`global_placement` (density retried upward on failure), CTS,
`repair_timing` (setup then hold), global route. **No unmapped cells** in
any of the twelve netlists — `stat -liberty` accounts for 100% of each
design's area.

### 4.1 Area and timing

| design | yosys pre-P&R area | **P&R area** | **GE** | period | setup slack | hold slack | search depth |
|---|---:|---:|---:|---:|---:|---:|---|
| Ascon-AEAD128 | — | 46 605 µm² | 12 416 | 3.9 ns | +0.00 ns | +0.14 ns | full sweep |
| hybrid r=128 | — | 41 044 µm² | 10 935 | 16.0 ns | +0.03 ns | +0.19 ns | full sweep |
| hybrid r=64 | — | 36 895 µm² | 9 829 | 16.0 ns | +0.02 ns | +0.12 ns | full sweep |
| tinyjambu | 24 016.8 µm² | 26 514 µm² | **7 064** | 20.0 ns | +16.11 ns | +0.08 ns | single point |
| xoodyak | 55 741.0 µm² | 68 960 µm² | 18 372 | 20.0 ns | +15.55 ns | +0.08 ns | single point |
| giftcofb | 52 910.7 µm² | 59 856 µm² | 15 946 | 20.0 ns | +14.59 ns | +0.08 ns | single point |
| grain | 36 277.3 µm² | 39 196 µm² | 10 442 | 20.0 ns | +15.69 ns | +0.07 ns | single point |
| sparkle | 91 260.0 µm² | 132 133 µm² | 35 202 | 25.0 ns | **+0.27 ns** | +0.13 ns | single point |
| elephant | 145 724.8 µm² | **169 458 µm²** | **45 145** | 25.0 ns | +8.27 ns | +0.11 ns | single point |
| isap | 84 786.3 µm² | 104 757 µm² | 27 908 | 20.0 ns | +14.93 ns | +0.10 ns | single point |
| photonbeetle | 81 592.0 µm² | 98 765 µm² | 26 312 | 30.0 ns | +21.63 ns | +0.09 ns | single point |
| romulus | 74 991.9 µm² | 85 117 µm² | 22 676 | 25.0 ns | +19.96 ns | +0.12 ns | single point |

The three Ascon-family designs were bracketed tightly on both sides (each
fails at the next period step down); the nine finalists were only tried at
one generous period each, so "period" for them is a starting guess, not a
found limit — see §1.2. **Hold is positive everywhere** — `repair_timing
-hold` in this flow (`sky.tcl`) fixes what the FPGA flow's zero input delay
leaves broken (§3.2, §8.1). The nine finalist rows above are a fresh
single-pass rerun against the bug-fixed RTL, same periods and same script
(`sky2.tcl`, an unmodified copy of the original `sky.tcl`) as the superseded
2026-08-29 pass; yosys reported no unmapped cells for any of the nine, same
as before.

sparkle's +0.27 ns setup slack at 25 ns means its real critical path is
~24.73 ns (~40 MHz) — likely close to its actual ceiling already, unlike the
other eight finalists where a tighter period would plausibly still close.

### 4.2 Power

Vectorless `report_power` for all twelve except the three Ascon-family
designs, which also have a VCD-annotated run (real activity from RTL
simulation, scope `tb/dut`) — marked † below. Vectorless numbers use default
toggle-rate estimates and should be read as relative ordering, not absolute
silicon power.

| design | combinational | clock | **total** | % combinational | source |
|---|---:|---:|---:|---:|---|
| Ascon-AEAD128 | — | — | 88.7 mW | — | VCD † |
| hybrid r=128 | — | — | 25.0 mW | — | VCD † |
| hybrid r=64 | — | — | 23.7 mW | — | VCD † |
| tinyjambu | 1.142 mW | 0.597 mW | 3.07 mW | 37.2% | vectorless |
| xoodyak | 1.118 mW | 1.084 mW | 4.48 mW | 25.0% | vectorless |
| giftcofb | 1.746 mW | 1.077 mW | 5.32 mW | 32.8% | vectorless |
| grain | 1.325 mW | 0.954 mW | 4.51 mW | 29.4% | vectorless |
| sparkle | **267.74 mW** | 0.926 mW | **272.21 mW** | **98.4%** | vectorless |
| elephant | 4.754 mW | 2.302 mW | 12.21 mW | 38.9% | vectorless |
| isap | 19.425 mW | 2.062 mW | 27.21 mW | 71.4% | vectorless |
| photonbeetle | 12.285 mW | 1.150 mW | 16.88 mW | 72.8% | vectorless |
| romulus | 2.464 mW | 1.545 mW | 7.02 mW | 35.1% | vectorless |

sparkle is still the outlier by nearly two orders of magnitude among the
vectorless numbers (now 272 mW, up from 233 mW in the superseded pass — the
one real bug fixed in this core removed a compensating byte-swap, i.e. it
removed logic, so the increase is not from added combinational area but from
how the default toggle-rate model responds to the corrected netlist), and it
is still almost entirely combinational (98.4%). That is architecturally
consistent — its entire permutation step (6 ARX-boxes plus a linear layer,
the largest single block of combinational logic in this set by pre-P&R
area) is one unregistered combinational cloud switching every cycle — but a
vectorless tool has to guess a default toggle rate for a block this size
with no real activity data, and that guess is the likely source of the
number being this far out of line. It needs a VCD-annotated re-run, as the
three Ascon-family designs got, before it should be trusted as a real power
figure — do not compare it directly to the † column above. photonbeetle also
moved substantially (3.5 mW → 16.9 mW, and from the least- to one of the
most-combinational-dominated finalists at 72.8%) — its 9-bug fix pass wired
in a previously-missing absorption path and a corrected round-constant
table, both of which are now real combinational logic the vectorless model
sees and the old, wrong-but-passing netlist did not have.

---

## 5. Cycles, throughput and functional verification

Cycle-accurate throughput requires either a fixed, documented cycle schedule
confirmed by simulation, or a KAT run. That exists for the three Ascon-family
designs (identical FSM, so a block always costs 8 cycles plus one handshake
cycle) and, now, for Ascon-AEAD128 too (full official KAT pass, §1.1
footnote 3 — on top of, not instead of, the shared-FSM schedule below).
**All nine finalists are now also KAT-verified** (§1.1) — the correctness
question this section originally flagged is closed for ten of the twelve
designs; the two hybrids now also have a KAT-style pass of their own,
against *self-generated* vectors rather than an official suite, since none
exists for them (§1.1 footnote 4) — all twelve designs in this file have now
been walked through some form of KAT vectors, real NIST ones for ten of
them, self-generated ones from each hybrid's own reference C for the
remaining two.

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

```
Ascon-family, all 3:
  initialisation            12 cycles   (p^12)
  per associated-data block  8 cycles   (p^8)
  per message block          8 cycles   (p^8, except the last)
  finalisation              12 cycles   (p^12)
```

| message / AD | Ascon & r=128 (16-byte blocks) | r=64 (8-byte blocks) |
|---|---|---|
| 0 B / 0 B | 29 | 29 |
| 0 B / 16 B | 47 | 56 |
| 0 B / 32 B | 56 | 74 |
| 64 B / 64 B | 110 | 182 |

Throughput is 16 bits/cycle for the wide-rate designs and 8 bits/cycle for
r=64 — see the headline energy-per-bit figures in §6.

| design | functional check | pass rate | throughput | energy / bit |
|---|---|---:|---:|---:|
| Ascon-AEAD128 | official NIST KAT suite (1089 vectors) + 16×16 length grid vs. C ref, both directions | **1089/1089 enc, 1089/1089 dec** (KAT); 256/256 enc, 256/256 dec (grid) | 880 Mbit/s (FPGA), 4.10 Gbit/s (sky130) | 20.5 pJ (FPGA), 21.6 pJ (sky130) |
| hybrid r=128 | self-generated KAT (1089 vectors)⁴ + 16×16 length grid vs. C ref, both directions | **1089/1089 enc, 1089/1089 dec** (KAT); 256/256 enc, 256/256 dec (grid) | 870 Mbit/s (FPGA), 1.00 Gbit/s (sky130) | **12.7 pJ** (FPGA), 24.9 pJ (sky130) |
| hybrid r=64 | self-generated KAT (1089 vectors)⁴ + 16×16 length grid vs. C ref, both directions | **1089/1089 enc, 1089/1089 dec** (KAT); 256/256 enc, 256/256 dec (grid) | **936 Mbit/s** (FPGA), 0.50 Gbit/s (sky130) | 20.3 pJ (FPGA), 47.4 pJ (sky130) |
| tinyjambu | official NIST KAT suite | **17127/17127 words** | 190 Mbit/s (FPGA), 0.228 Gbit/s (sky130) | 399 pJ ² (FPGA), 13.4 pJ (sky130) |
| xoodyak | official NIST KAT suite | 19305/19305 words | **1.42 Gbit/s** (FPGA), 2.40 Gbit/s (sky130) | 68.3 pJ ² (FPGA), **1.87 pJ** (sky130) |
| giftcofb | official NIST KAT suite | 19305/19305 words | 284 Mbit/s (FPGA), 0.415 Gbit/s (sky130) | 240 pJ ² (FPGA), 12.8 pJ (sky130) |
| grain | official NIST KAT suite | 17127/17127 words | 80.0 Mbit/s (FPGA), 0.108 Gbit/s (sky130) | 975 pJ ² (FPGA), 41.9 pJ (sky130) |
| sparkle | official NIST KAT suite | 19305/19305 words | 484 Mbit/s (FPGA) ³, 0.293 Gbit/s (sky130) ³ | 203 pJ ² ³ (FPGA), **930 pJ** ⁴ (sky130) |
| elephant | official NIST KAT suite | 17127/17127 words | 42.6–85.7 Mbit/s (FPGA) ⁵, 0.057–0.114 Gbit/s (sky130) ⁵ | 750–1500 pJ ² ⁵ (FPGA), 107–215 pJ ⁵ (sky130) |
| isap | official NIST KAT suite | 19305/19305 words | 233 Mbit/s (FPGA), 0.315 Gbit/s (sky130) | 494 pJ ² (FPGA), 86.3 pJ (sky130) |
| photonbeetle | official NIST KAT suite | 19305/19305 words | 594 Mbit/s (FPGA) ¹, 0.622 Gbit/s (sky130) ¹ | 128 pJ ² ¹ (FPGA), 27.2 pJ ¹ (sky130) |
| romulus | official NIST KAT suite | 19305/19305 words | 386 Mbit/s (FPGA) ³, 0.551 Gbit/s (sky130) ³ | 187 pJ ² ³ (FPGA), 12.7 pJ ³ (sky130) |

² **The nine finalists' FPGA energy/bit divides throughput into total
on-chip power (§3.3), not dynamic power alone.** The three Ascon-family
FPGA energy figures above use *dynamic* power only (SAIF-annotated,
§3.3) — the static/clock 57 mW is a fixed device property (§3.3's own
note) excluded on the reasoning that it doesn't scale with the design's
own switching activity. The finalists' vectorless FPGA `report_power`
never splits dynamic from static (§3.3: "—" in both columns, only a
total), so there is nothing to exclude — their FPGA pJ/bit figures are
power-in ÷ bits-out with no component removed. **Do not compare a
finalist's FPGA pJ/bit against the three Ascon-family FPGA pJ/bit figures
directly** — the finalist numbers are worse (bigger) by construction,
not necessarily by design. sky130 energy/bit uses total power for all
twelve alike (the Ascon-family sky130 run isn't split into
dynamic/static either, §4.2), so the sky130 column *is* directly
comparable across all twelve.
³ xoodyak, sparkle and romulus each have only **one** clean, simulation-measured
block-boundary crossing inside the 0–32-byte range the official KAT grid
reaches (§5 table above) — real and simulation-derived, not assumed, but
not independently confirmed to repeat for a second block the way
tinyjambu/giftcofb/isap's numbers are.
⁴ sparkle's sky130 energy/bit inherits the unreliable vectorless power
number flagged in §4.2 (272 mW, 98% combinational, likely a default-activity
artifact of one huge unregistered combinational round) — treat 930 pJ as
downstream of that same caveat, not a new, independent problem.
⁵ **elephant's numbers are a bracket, not a point estimate** — its one
observable block-boundary crossing costs two Spongent-π[160] calls
back-to-back rather than a repeatable single-call constant (§5 table
above); the low end of each range uses the single clean first-block call
(84 cycles/20-byte block), the high end uses the two-call crossing (169
cycles/20-byte block). Both bounds are real simulation numbers; which one
(if either) best represents a long message is not resolved by the
available KAT range.

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
frequency-independent and those three columns compare directly. The nine
finalists' sky130 power is vectorless (§4.2), not simulation-derived, so
their sky130 energy/bit inherits that same caveat regardless of how exactly
the cycle count was measured.

---

## 6. Where each design wins

**Among the three Ascon-family designs: on FPGA, pick r=64.** It is the
smallest (−24% slices), the fastest (2.15×), and has the highest throughput
— 936 Mbit/s against 880 for Ascon — *despite* absorbing half as much data
per permutation, and it keeps Ascon's 192-bit capacity. **On ASIC, pick
Ascon**: 256 MHz against 62.5 MHz, 4.1× the throughput, and the best energy
per bit — its area disadvantage (+26% GE over r=64) doesn't come close to
paying for an 8× throughput deficit. **r=128 is the FPGA energy champion**
at 12.7 pJ/bit, ~37% better than either alternative, but it's the only
design of the three with a 128-bit capacity — the weakest security
parameter. §7 explains why FPGA and ASIC disagree so sharply here.

**Across the full field of twelve: tinyjambu wins on every measured axis** —
smallest FPGA footprint, highest FPGA Fmax, smallest sky130 area, lowest
sky130 power — and that remains true now that all twelve designs are
KAT-verified (§1.1), not just tinyjambu. TinyJAMBU's whole design premise is
an extremely small, simple permutation, which is also why it needed zero
fixes to pass the KAT grid that the other eight finalists needed 42 bugs
fixed for. **elephant and sparkle sit at the opposite end** — largest by a
wide margin on both targets — for the structural reasons in §7, not because
they are "worse ciphers"; NIST evaluated all nine finalists on security and
multiple cost metrics, and this repo measures only one implementation choice
(round-per-cycle) of each, now a *correct* one for all nine.

---

## 7. Why some designs cost more than others

Two different bottlenecks dominate depending on the target and the design.

**Among the three Ascon-family designs, the FPGA bottleneck is the padding
mask, not the cipher.** The critical path is `din_bytes → st_reg`, 18 logic
levels of which 15 are CARRY4 — a borrow chain from

```verilog
wire [127:0] mask = full ? {128{1'b1}} : ((128'd1 << shamt) - 128'd1);
```

The `- 1` is what costs it. This is why Ascon and r=128 land within 1% of
each other (55.0 vs 54.4 MHz) despite completely different round functions:
both are measuring the same mask. r=64 is the natural experiment — its rate
is 64 bits, so the same expression builds a 64-bit chain instead of a
128-bit one, logic levels drop 18 → 10, and the clock doubles. That is the
mask being measured, not the cipher. **On ASIC the mask is cheap** —
`repair_timing` optimises it away, and the real architectural difference
appears: Ascon's XOR/AND round collapses to a 3.9 ns path, while SIPROUND
contains four chained 64-bit additions that no optimiser can shorten,
holding both hybrids at 16.0 ns regardless of their rate. This also confirms
the two hybrids share a round function: identical ASIC Fmax, differing only
in area and throughput. A byte-wise decoder (replacing the shift-and-subtract
mask with a per-lane comparator) would remove the FPGA chain entirely and
lift all three Ascon-family designs — not attempted here.

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

### 8.1 Applies to all twelve designs

1. **Hold on FPGA is a constraint artefact, not a design defect**, on every
   one of the twelve. The worst hold path is always at an input port (e.g.
   `key[116] → k_r_reg[116]/D`) because `set_input_delay 0` gives it no
   launch delay to absorb. There is not a single register-to-register hold
   violation in any design on either target, and on sky130 **all twelve
   have positive hold slack**. Realistic input delays would remove the FPGA
   artefact too; only actually re-verified for the three Ascon-family
   designs (+0.14/+0.19/+0.12 ns after the fix), not re-checked per finalist.
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
4. **The two hybrids are unanalysed constructions.** Neither has had
   cryptanalysis. These are engineering measurements, not a security
   argument, and the same applies by extension to any of the nine
   finalists' *specific implementation choices* here (this repo did not
   re-derive or re-verify any of the nine algorithms' own published security
   analyses — those are NIST's and each design team's, not re-litigated here).

### 8.2 Ascon-family designs only (deeper first pass — §1.2)

5. **SAIF nets matched are 27–39%**, because activity comes from RTL
   simulation while the netlist is post-implementation. Vivado rates Ascon
   "High" and both hybrids "Medium"; r=64 matches fewest because it has the
   fewest nets. A post-implementation timing simulation would raise all three.
6. **ASIC power activity is annotated at top-level ports only** — the VCD is
   from RTL simulation, so only port names match the mapped netlist and
   OpenSTA propagates inward. Gate-level annotation is *possible* on sky130
   (SkyWater publishes behavioural Verilog models at
   `google/skywater-pdk-libs-sky130_fd_sc_hd`) but needs a gate-level
   simulation pass, not attempted for any of the twelve designs.

### 8.3 The 9 finalists only (lighter pass — §1.2)

7. **sky130 Fmax is not a searched minimum** for any of the nine — see §1.2
   and §4.1. Treat sky130 Fmax figures as a floor, likely to improve with a
   real sweep, except sparkle (already near its ceiling — §4.1).
8. **Power is vectorless** for all nine (no RTL-simulation-derived
   activity). sparkle's number in particular (§4.2) should not be trusted
   without a VCD-annotated re-run.
9. **Vivado's period search was lighter** (3 iterations vs. up to 7) than
   the Ascon-family designs' — Fmax figures are close to each design's
   ceiling but not as exhaustively confirmed.
10. These are nine different algorithms (including tinyjambu) with nine
    different security margins, round counts and tag sizes — smaller/faster
    is not "better" in isolation; it is one input into a design tradeoff
    that also depends on each algorithm's security case, out of scope here.
11. **These are rerun numbers, not a second, independent design pass.** The
    FPGA and sky130 methodology (scripts, starting periods, search depth) is
    identical to the superseded 2026-08-29 pass — only the RTL changed. A
    real re-tuned pass (deeper period search, per-design starting points
    picked for the fixed RTL rather than reused from the buggy RTL) would
    likely find tighter Fmax for several of these nine, the same way the
    Ascon-family designs' 7-iteration search does better than a 3-iteration
    one would.

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

| Metric | Tool | File / scope |
|---|---|---|
| Functional pass/fail, cycle counts (Ascon family, 16×16 grid) | Vivado xsim | `xsim/xsim_*.log`, `xsim/xs_f_*.log` (2026-08-25/26 scratchpad, RTL unchanged since) |
| KAT pass/fail (tinyjambu) | Vivado xsim | testbench walking the official NIST KAT vectors |
| KAT pass/fail (8 other finalists) | Vivado xsim | `kv2/<design>/xsim.log`, one directory per design, testbench generated by `kv2/gen.py` from the official NIST LWC KAT files, walking the real PDI/SDI/DO word-stream protocol; all eight show `RESULT words N/N ... ALL_PASS` (17127 or 19305 words, matching §1.1), run 2026-09-02 against the RTL in `verilog/` directly |
| KAT pass/fail (Ascon-AEAD128) | Vivado xsim | `kat_ascon/tb_ascon_kat.v` (adapted from `xsim/tb_ascon.v`) driving `kat_ascon/stim_ascon_kat.mem`, generated by `kat_ascon/gen_stim.py` from the official `LWC_AEAD_KAT_128_128.txt` (1089 vectors) against the unmodified RTL in `verilog/`; shows `KAT RESULT encrypt 1089/1089 decrypt 1089/1089` / `XSIM_ALL_PASS`, run 2026-09-02, this session's scratchpad, under `kat_ascon/` |
| KAT pass/fail (hybrids, self-generated) | Vivado xsim | No official NIST KAT suite exists for `asconsip_aead.v` / `asconsip64_aead.v` (not a NIST submission), so vectors were generated with NIST's own unmodified `kat_hybrid/r128/genkat_aead.c` / `kat_hybrid/r64/genkat_aead.c` (identical copies of `ascon-c`'s `tests/genkat_aead.c`, the same generator used for Ascon-AEAD128's own suite above) re-linked against `ascon-siphash/asconsip.c` / `asconsip64.c` via `kat_hybrid/r128/api.h`+`crypto_aead.h` / `kat_hybrid/r64/api.h`+`crypto_aead.h`, producing `kat_hybrid/r128/LWC_AEAD_KAT_r128.txt` / `kat_hybrid/r64/LWC_AEAD_KAT_r64.txt` (1089 vectors each); `kat_hybrid/tb_asconsip_kat.v` / `tb_asconsip64_kat.v` (adapted from `kat_ascon/tb_ascon_kat.v`, r=64 narrowed to its 8-byte block/64-bit `din`) drove `kat_hybrid/stim_r128_kat.mem` / `stim_r64_kat.mem` (from `kat_hybrid/gen_stim.py`, a copy of `kat_ascon/gen_stim.py`) against the unmodified RTL in `verilog/`; `kat_hybrid/xsim_r128.log` / `xsim_r64.log` both show `KAT RESULT encrypt 1089/1089 decrypt 1089/1089` / `XSIM_ALL_PASS`, run 2026-09-04, this session's scratchpad, under `kat_hybrid/` — see `verilog/README.md` for why this is not equivalent to an official NIST suite |
| Cycle schedule / throughput basis (9 finalists, §5) | Vivado xsim | `kv2cyc/<design>/cyc.log`, one directory per design (`kv2cyc/tinyjambu/` sourced from `tj/*.mem` instead of `kv2/`), each the exact `kv2/gen.py`-generated stimulus already proven `ALL_PASS` in §1.1, replayed unmodified against the RTL in `verilog/` through `kv2cyc/tb_template_cyc.v` (`kv2/tb_template.v` plus `$time` stamps around each of the 2178 transactions, no driver-logic change); all nine re-confirm `ALL_PASS` under this instrumented testbench; steady-state cycles/block extracted by differencing the AD=0, PT=0..32-byte encrypt-transaction timestamps (`kv2cyc/analyze.py`), run 2026-09-03, this session's scratchpad |
| FPGA utilization, route status, timing search (Ascon family) | Vivado | `synth_design`/`.../route_design` reports, 2026-08-25 scratchpad |
| FPGA utilization, route status, timing search (9 finalists) | Vivado | `fin_v/vivado_fin2.log` + `fin_v/out/*_util.txt`, `*_timing.txt`, `*_route.txt` — rerun 2026-09-02, this session's scratchpad |
| FPGA critical path (Ascon family) | Vivado | `report_timing` path reports |
| FPGA power, SAIF period-matched (Ascon family) | Vivado `report_power` | period-matched SAIF activity |
| FPGA power, vectorless (9 finalists) | Vivado `report_power` | `fin_v/out/*_power_vectorless.txt`, rerun 2026-09-02 |
| FPGA determinism proof (Ascon family) | Vivado | single-threaded re-run, `DETERMINISM` check |
| sky130 period sweep (Ascon family) | OpenROAD | full sweep to closing limit, 2026-08-26 scratchpad |
| sky130 single-point run (9 finalists) | OpenROAD | `fin_sky/<design>_yosys.log` + `fin_sky/<design>_<period>.log`, one fixed generous period per design — rerun 2026-09-02, this session's scratchpad |
| sky130 area, cells, skew, slack | OpenROAD | `report_design_area`, `report_cell_usage`, `report_clock_skew` |
| sky130 power, VCD-annotated (Ascon family) | OpenROAD `report_power` | `read_power_activities -vcd`, scope `tb/dut` |
| sky130 power, vectorless (9 finalists) | OpenROAD `report_power` | no activity annotation, in the same `fin_sky/*.log` as the area/timing rerun above |
| sky130 cell area / unmapped-cell check | yosys | `stat -liberty`, in the same `fin_sky/*_yosys.log` |
| sky130 platform | ORFS | `~/pdks/sky130hd/` |

Vivado reports carry their own header — tool version, `Device:
xc7a12ticsg325-1L`, `Design State: Routed`, timestamp, host — so each is
self-identifying. Raw logs are working files under two Claude Code session
scratchpads, not part of this repo; this table records where each number
came from, not a browsable path. The Ascon-family and original (superseded)
finalist logs are under session `2ea5e700-3913-4d76-b400-fd85c2f50334`; the
KAT reruns that confirmed all nine finalists (`kv2/`) are in that same
scratchpad, generated 2026-08-31 through 2026-09-02; the FPGA/sky130 finalist
*rerun* that produced every finalist number in §2–§4 of this file is in a
separate session's scratchpad, `e5181ceb-5877-438f-bd50-70d4bd26644e`, under
`fin_v/` (Vivado) and `fin_sky/` (yosys + OpenROAD), both adapted line-for-line
from that first session's `fin_v/flow_fin.tcl` and `fin_sky/sky.tcl` with only
the RTL source path changed to point at the current, bug-fixed `verilog/`.
The nine finalists' §5 cycle-schedule extraction (`kv2cyc/`) is also in that
second session's scratchpad, generated 2026-09-03 by copying each design's
already-proven `.mem` stimulus out of the first session's `kv2/` (`tj/` for
tinyjambu) rather than regenerating it. The two hybrids' self-generated KAT
run (`kat_hybrid/`) is also in the second session's scratchpad
(`e5181ceb-5877-438f-bd50-70d4bd26644e`), generated 2026-09-04 by re-linking
the first session's unmodified `ascon-c/tests/genkat_aead.c` (copied
byte-for-byte into `kat_hybrid/r128/` and `kat_hybrid/r64/` so its own
quote-included `api.h`/`crypto_aead.h` resolve to the per-hybrid shims
there, not the original Ascon ones) against `ascon-siphash/asconsip.c` /
`asconsip64.c` in this repo, and by adapting `kat_ascon/tb_ascon_kat.v` /
`gen_stim.py` from the first session's KAT run — `kat_ascon/` itself is
untouched.
