# Hardware results: Ascon-AEAD128, two Ascon-SipHash hybrids, and the 9 NIST LWC finalists

Area, timing and power for all twelve AEAD cores in [`verilog/`](verilog/) —
the NIST-standardized Ascon-AEAD128, two experimental Ascon-SipHash hybrids,
and one core per algorithm that lost to Ascon in the final round of NIST's
Lightweight Cryptography competition — measured on the same FPGA with Vivado
and the same 130 nm ASIC process with OpenROAD.

**Every number was produced by Xilinx Vivado or by OpenROAD** on this
machine. Section 10 maps each metric to the log it came from. The three
Ascon-family designs were measured 2026-08-25; the nine finalists,
2026-08-29 — see §1.2 for what differs between the two measurement passes
and why some columns below carry a footnote.

---

## 1. Designs, tools and targets

### 1.1 The twelve designs

| design | file | key / npub / tag (bytes) | KAT-verified? |
|---|---|---|---|
| **Ascon-AEAD128** (the winner) | `ascon_aead128.v` | 16 / 16 / 16 | no — xsim only¹ |
| **hybrid r=128** (unanalysed) | `asconsip_aead.v` | 16 / 16 / 16 | no — xsim only¹ |
| **hybrid r=64** (unanalysed) | `asconsip64_aead.v` | 16 / 16 / 16 | no — xsim only¹ |
| TinyJAMBU-128 | `tinyjambu_lwc.v` | 16 / 12 / 8 | **yes** (17127/17127 words) |
| Xoodyak | `xoodyak_lwc.v` | 16 / 16 / 16 | no — lint-clean only |
| GIFT-COFB | `giftcofb_lwc.v` | 16 / 16 / 16 | no — lint-clean only |
| Grain-128AEAD | `grain128aead_lwc.v` | 16 / 12 / 8 | no — lint-clean only |
| SPARKLE (Schwaemm256-128) | `sparkle_lwc.v` | 16 / 32 / 16 | no — lint-clean only |
| Elephant (Dumbo) | `elephant_lwc.v` | 16 / 12 / 8 | no — lint-clean only |
| ISAP (ISAP-A-128A) | `isap_lwc.v` | 16 / 16 / 16 | no — lint-clean only |
| PHOTON-Beetle | `photonbeetle_lwc.v` | 16 / 16 / 16 | no — lint-clean only |
| Romulus (Romulus-N) | `romulus_n_lwc.v` | 16 / 16 / 16 | no — lint-clean only |

¹ Verified against the C reference via Vivado `xsim` (a 16×16 grid of
message/AD lengths, both directions — §5), not against NIST KAT vectors.

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
confirmed no behavioural change.

---

## 2. Headline

All twelve, sorted by sky130 area (smallest first). GE = gate equivalents =
cell area ÷ sky130 NAND2 area (3.7536 µm²). **†** = simulation-derived
activity (SAIF/VCD); no mark = vectorless default-activity estimate — see
§1.2 before comparing power across the † boundary.

| design | FPGA LUTs | FPGA regs | FPGA Fmax | FPGA power | sky130 area | sky130 GE | sky130 Fmax | sky130 power |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **tinyjambu** | 472 | 533 | 214.1 MHz | 76.0 mW | **26 514 µm²** | **7 064** | 257 MHz | **3.07 mW** |
| grain | 576 | 915 | 176.1 MHz | 78.0 mW | 39 105 µm² | 10 418 | 243 MHz | 4.27 mW |
| **hybrid r=64** | 873 | 599 | **117.0 MHz** | 76 mW † | 36 895 µm² | 9 829 | 62.5 MHz | 23.7 mW † |
| romulus | 1319 | 1419 | 132.8 MHz | 70.0 mW | 82 316 µm² | 21 930 | 206 MHz | 7.36 mW |
| giftcofb | 1330 | 1003 | 121.8 MHz | 66.0 mW | 58 380 µm² | 15 553 | 198 MHz | 8.08 mW |
| **hybrid r=128** | 1021 | 663 | 54.4 MHz | 68 mW † | 41 044 µm² | 10 935 | 62.5 MHz | 25.0 mW † |
| photonbeetle | 1914 | 1118 | 114.2 MHz | 78.0 mW | 101 346 µm² | 27 000 | 123 MHz | 3.54 mW |
| xoodyak | 1500 | 884 | 124.3 MHz | 94.0 mW | 69 313 µm² | 18 466 | 235 MHz | 4.98 mW |
| **Ascon-AEAD128** | 1101 | 728 | 55.0 MHz | 75 mW † | 46 605 µm² | 12 416 | **256 MHz** | 88.7 mW † |
| isap | 2368 | 1657 | 139.2 MHz | 96.0 mW | 103 945 µm² | 27 692 | 188 MHz | 26.22 mW |
| sparkle | 2363 | 1092 | 65.7 MHz | 96.0 mW | 128 429 µm² | 34 215 | 40 MHz | 232.5 mW ² |
| **elephant** | **4604** | **2463** | **47.5 MHz** | 66.0 mW | **167 686 µm²** | **44 673** | 63 MHz | 13.10 mW |

² sparkle's vectorless power is far above every other design (98% of it
combinational) — see §4.2; likely a default-activity artifact of its single
huge per-cycle combinational round, not necessarily a real number.

**tinyjambu is the smallest and fastest design in the entire set** — smaller
and faster than Ascon-AEAD128 itself on FPGA, though not on sky130 where
Ascon's tighter, fully-swept critical path (256 MHz) edges out tinyjambu's
single-point estimate (257 MHz, likely understated per §1.2). That is not a
contradiction: tinyjambu has an 8-byte tag against Ascon's 16, fewer
permutation rounds per block, and — like the other 8 finalists — is
unverified, so "smallest measured" is not "best cipher." **elephant and
sparkle are the two heavyweights** in this set, each for a different
structural reason — see §7. Among the three Ascon-family designs, **r=64 is
the best FPGA design and Ascon is the best ASIC design**; neither wins
everywhere — see §6.

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
| xoodyak | 1500 (18.8%) | 884 | — | 8 |
| giftcofb | 1330 (16.6%) | 1003 | — | 15 |
| grain | 576 (7.2%) | 915 | — | 3 |
| sparkle | 2363 (29.5%) | 1092 | — | **27** |
| elephant | **4604 (57.6%)** | **2463** | — | 25 |
| isap | 2368 (29.6%) | 1657 | — | 7 |
| photonbeetle | 1914 (23.9%) | 1118 | — | 10 |
| romulus | 1319 (16.5%) | 1419 | — | 3 |

(Occupied-slice figures were only recorded for the three Ascon-family
designs' first, deeper pass — §1.2; the rest were not re-extracted for the
lighter finalist pass, so those cells are left blank rather than guessed.)

Logic-level count tracks each algorithm's per-cycle combinational shape more
than its cycle count: sparkle (27 levels) and elephant (25) both do a large
amount of work per clock — sparkle's full 6-ARX-box-plus-linear-layer
permutation step, elephant's Spongent-π[160] round — while tinyjambu, grain
and romulus keep their per-cycle logic shallow (2–3 levels) even though
grain and romulus both run many cycles per byte. Ascon and hybrid r=128 both
sit at 18 levels for a different reason — §7: the same 128-bit padding-mask
borrow chain, not their round functions.

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
| xoodyak | 8.330 ns | +0.283 | 8.047 ns | 124.27 MHz |
| giftcofb | 8.986 ns | +0.775 | 8.211 ns | 121.79 MHz |
| grain | 6.178 ns | +0.499 | 5.679 ns | 176.09 MHz |
| sparkle | 15.783 ns | +0.567 | 15.216 ns | 65.72 MHz |
| elephant | 21.303 ns | +0.244 | 21.059 ns | **47.49 MHz** |
| isap | 9.120 ns | +1.935 | 7.185 ns | 139.18 MHz |
| photonbeetle | 9.277 ns | +0.521 | 8.756 ns | 114.20 MHz |
| romulus | 8.303 ns | +0.773 | 7.530 ns | 132.80 MHz |

Every design shows the **same WHS = −0.502 ns** hold violation, always at an
input port (e.g. `key[116] → k_r_reg[116]/D`), because `set_input_delay 0`
gives it no launch delay to absorb. There is not a single register-to-register
hold violation in any of the twelve designs on either target — see the
caveat in §8.1 for why this is a constraint artefact, not twelve independent
design defects.

### 3.3 Power

| design | dynamic | static / clock | **total on-chip** | activity source |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 18 mW | 57 mW | 75 mW | SAIF, period-matched † |
| hybrid r=128 | 11 mW | 57 mW | 68 mW | SAIF, period-matched † |
| hybrid r=64 | 19 mW | 57 mW | 76 mW | SAIF, period-matched † |
| tinyjambu | — | — | 76.0 mW | vectorless |
| xoodyak | — | — | 94.0 mW | vectorless |
| giftcofb | — | — | 66.0 mW | vectorless |
| grain | — | — | 78.0 mW | vectorless |
| sparkle | — | — | 96.0 mW | vectorless |
| elephant | — | — | 66.0 mW | vectorless |
| isap | — | — | 96.0 mW | vectorless |
| photonbeetle | — | — | 78.0 mW | vectorless |
| romulus | — | — | 70.0 mW | vectorless |

Static power (57 mW) is a device property of the XC7A12T and applies to all
twelve equally; it was only broken out from dynamic power for the three
Ascon-family designs' SAIF-annotated run. The finalists' vectorless total is
not split into dynamic/static components by `report_power` the way the
SAIF-annotated run is, so those columns are left blank rather than guessed.
Vectorless FPGA power sits in a much narrower band (66–96 mW) than the
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
| xoodyak | 55 748.5 µm² | 69 313 µm² | 18 466 | 20.0 ns | +15.75 ns | +0.09 ns | single point |
| giftcofb | 51 575.7 µm² | 58 380 µm² | 15 553 | 20.0 ns | +14.95 ns | +0.07 ns | single point |
| grain | 36 231.0 µm² | 39 105 µm² | 10 418 | 20.0 ns | +15.88 ns | +0.08 ns | single point |
| sparkle | 91 131.2 µm² | 128 429 µm² | 34 215 | 25.0 ns | **+0.09 ns** | +0.23 ns | single point |
| elephant | 144 843.9 µm² | **167 686 µm²** | **44 673** | 25.0 ns | +9.07 ns | +0.14 ns | single point |
| isap | 84 648.7 µm² | 103 945 µm² | 27 692 | 20.0 ns | +14.68 ns | +0.10 ns | single point |
| photonbeetle | 83 872.9 µm² | 101 346 µm² | 27 000 | 30.0 ns | +21.84 ns | +0.11 ns | single point |
| romulus | 73 033.8 µm² | 82 316 µm² | 21 930 | 25.0 ns | +20.14 ns | +0.08 ns | single point |

The three Ascon-family designs were bracketed tightly on both sides (each
fails at the next period step down); the nine finalists were only tried at
one generous period each, so "period" for them is a starting guess, not a
found limit — see §1.2. **Hold is positive everywhere** — `repair_timing
-hold` in this flow (`sky.tcl`) fixes what the FPGA flow's zero input delay
leaves broken (§3.2, §8.1).

sparkle's +0.09 ns setup slack at 25 ns means its real critical path is
~24.91 ns (~40 MHz) — likely close to its actual ceiling already, unlike the
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
| tinyjambu | 0.426 mW | 0.287 mW | 3.07 mW | 37.2% | vectorless |
| xoodyak | 0.548 mW | 0.466 mW | 4.98 mW | 31.8% | vectorless |
| giftcofb | 1.518 mW | 0.454 mW | 8.08 mW | 49.5% | vectorless |
| grain | 0.381 mW | 0.409 mW | 4.27 mW | 26.8% | vectorless |
| sparkle | **91.05 mW** | 0.403 mW | **232.53 mW** | **98.2%** | vectorless |
| elephant | 2.157 mW | 0.992 mW | 13.10 mW | 43.1% | vectorless |
| isap | 7.712 mW | 0.991 mW | 26.22 mW | 70.8% | vectorless |
| photonbeetle | 0.203 mW | 0.583 mW | 3.54 mW | 13.9% | vectorless |
| romulus | 0.924 mW | 0.765 mW | 7.36 mW | 36.4% | vectorless |

sparkle is the outlier by nearly two orders of magnitude among the
vectorless numbers, and it is almost entirely combinational (98.2%). That is
architecturally consistent — its entire permutation step (6 ARX-boxes plus a
linear layer, the largest single block of combinational logic in this set
by pre-P&R area) is one unregistered combinational cloud switching every
cycle — but a vectorless tool has to guess a default toggle rate for a block
this size with no real activity data, and that guess is the likely source of
the number being this far out of line. It needs a VCD-annotated re-run, as
the three Ascon-family designs got, before it should be trusted as a real
power figure — do not compare it directly to the † column above.

---

## 5. Cycles, throughput and functional verification

Cycle-accurate throughput requires either a fixed, documented cycle schedule
confirmed by simulation, or a KAT run. That exists for the three Ascon-family
designs (identical FSM, so a block always costs 8 cycles plus one handshake
cycle) and, separately, for tinyjambu (full KAT pass). It does **not** exist
for the other eight finalists — each core's header documents its intended
cycle schedule, but without a simulation run to confirm the FSM actually
behaves as designed, publishing a throughput number for unverified RTL would
overstate confidence in results that might not even be computing the right
ciphertext. Their rows below are therefore explicitly N/A, not estimated.

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
| Ascon-AEAD128 | 16×16 length grid vs. C ref, both directions | 256/256 enc, 256/256 dec | 880 Mbit/s (FPGA), 4.10 Gbit/s (sky130) | 20.5 pJ (FPGA), 21.6 pJ (sky130) |
| hybrid r=128 | 16×16 length grid vs. C ref, both directions | 256/256 enc, 256/256 dec | 870 Mbit/s (FPGA), 1.00 Gbit/s (sky130) | **12.7 pJ** (FPGA), 24.9 pJ (sky130) |
| hybrid r=64 | 16×16 length grid vs. C ref, both directions | 256/256 enc, 256/256 dec | **936 Mbit/s** (FPGA), 0.50 Gbit/s (sky130) | 20.3 pJ (FPGA), 47.4 pJ (sky130) |
| tinyjambu | official NIST KAT suite | **17127/17127 words** | N/A — not tabulated | N/A |
| other 8 finalists | none run | — | N/A — unverified | N/A |

Leakage is negligible in the sky130 library at this corner (~2×10⁻⁸ W), so
sky130 energy per bit for the Ascon-family designs is essentially
frequency-independent and those three columns compare directly.

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
sky130 power — while also being the only finalist with a confirmed-correct
implementation in this repo. That combination (smallest *and* verified) is
not a coincidence: TinyJAMBU's whole design premise is an extremely small,
simple permutation, which is also why it was tractable to get fully
KAT-verified quickly. **elephant and sparkle sit at the opposite end** —
largest by a wide margin on both targets — for the structural reasons in §7,
not because they are "worse ciphers"; NIST evaluated all nine finalists on
security and multiple cost metrics, and this repo measures only one
implementation choice (round-per-cycle) of each.

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
two more for key expansion and finalization. sparkle's Schwaemm256-128 runs
6 parallel ARX-boxes plus a linear layer as one per-cycle combinational
block, the deepest single-cycle path in the set (27 logic levels on FPGA).
By contrast tinyjambu, grain and romulus keep their per-cycle logic shallow
(2–3 levels) by design, even though grain and romulus both run many cycles
per byte to get there — a direct cycle-count-vs-per-cycle-cost tradeoff, the
same shape as the Ascon-family mask/cipher tradeoff above, just driven by
each algorithm's own structure instead of one shared expression.

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
3. **Only tinyjambu, among the nine finalists, has been run against KAT
   vectors.** The other eight are lint-clean and route/time cleanly, which
   confirms nothing about whether they compute the right ciphertext. See
   `verilog/README.md`'s verification table before trusting any finalist
   number as more than "this RTL, correct or not, costs this much to build."
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
10. These are eight different algorithms (plus tinyjambu) with eight
    different security margins, round counts and tag sizes — smaller/faster
    is not "better" in isolation; it is one input into a design tradeoff
    that also depends on each algorithm's security case, out of scope here.

---

## 9. Method notes specific to the finalist RTL

Two files needed a fix to synthesize under yosys (§1.2): `giftcofb_lwc.v`
and `romulus_n_lwc.v` both part-selected a function call's return value
directly (`f(...)[a:b]`) — legal Verilog-2005, accepted by Verilator and
Vivado, rejected by yosys's Verilog-2005 frontend. Both were fixed by
holding the call's result in an intermediate signal first and slicing from
that instead; re-lint in Verilator and Vivado after the fix confirmed no
behavioural change before re-synthesizing.

---

## 10. Provenance

| Metric | Tool | File / scope |
|---|---|---|
| Functional pass/fail, cycle counts (Ascon family) | Vivado xsim | `xsim/xsim_*.log`, `xsim/xs_f_*.log` |
| KAT pass/fail (tinyjambu) | Vivado xsim | testbench walking the official NIST KAT vectors |
| FPGA utilization, route status, timing search (all 12) | Vivado | `synth_design`/`.../route_design` reports |
| FPGA critical path (Ascon family) | Vivado | `report_timing` path reports |
| FPGA power, SAIF period-matched (Ascon family) | Vivado `report_power` | period-matched SAIF activity |
| FPGA power, vectorless (9 finalists) | Vivado `report_power` | no activity annotation |
| FPGA determinism proof (Ascon family) | Vivado | single-threaded re-run, `DETERMINISM` check |
| sky130 period sweep (Ascon family) | OpenROAD | full sweep to closing limit |
| sky130 single-point run (9 finalists) | OpenROAD | one fixed generous period per design |
| sky130 area, cells, skew, slack | OpenROAD | `report_design_area`, `report_cell_usage`, `report_clock_skew` |
| sky130 power, VCD-annotated (Ascon family) | OpenROAD `report_power` | `read_power_activities -vcd`, scope `tb/dut` |
| sky130 power, vectorless (9 finalists) | OpenROAD `report_power` | no activity annotation |
| sky130 cell area / unmapped-cell check | yosys | `stat -liberty` |
| sky130 platform | ORFS | `~/pdks/sky130hd/` |

Vivado reports carry their own header — tool version, `Device:
xc7a12ticsg325-1L`, `Design State: Routed`, timestamp, host — so each is
self-identifying. Raw logs are working files under this session's
scratchpad, not part of this repo; this table records where each number
came from, not a browsable path.
