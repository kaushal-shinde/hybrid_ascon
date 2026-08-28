# Hardware results: Ascon-AEAD128 and two Ascon-SipHash hybrids

Area, timing and power for the three AEAD cores in [`verilog/`](verilog/),
measured on an FPGA with Vivado and on a 130 nm ASIC process with OpenROAD.

**Every number was produced by Xilinx Vivado or by OpenROAD** on this machine.
Section 9 maps each metric to the log it came from. Measured 2026-08-25.

---

## 1. Designs, tools and targets

| design | state | rate | capacity | file |
|---|---|---|---|---|
| **Ascon-AEAD128** | 320 bits (5 words) | 128 | 192 | `verilog/ascon_aead128.v` |
| **hybrid r=128** | 256 bits (4 words) | 128 | **128** | `verilog/asconsip_aead.v` |
| **hybrid r=64** | 256 bits (4 words) | **64** | **192** | `verilog/asconsip64_aead.v` |

The two hybrids are architecturally identical — same 256-bit state, same round
(Ascon's round constant then SipHash's SIPROUND), same 12/8 round counts, same
duplex mode. They differ only in where the rate ends and the capacity begins.
The r=64 variant restores Ascon-AEAD128's 192-bit capacity.

| | |
|---|---|
| FPGA implementation | Vivado v2026.1, `set_param general.maxThreads 1` |
| FPGA part | **xc7a12ticsg325-1L** — Artix-7, CSG325, −1L, 8000 LUTs / 16000 FFs |
| Simulation | Vivado `xvlog` / `xelab` / `xsim` |
| ASIC P&R, optimisation, STA, power | OpenROAD 2.0-12381-g01bba3695 |
| ASIC synthesis front-end | yosys 0.38+92 (OpenROAD does not synthesise) |
| ASIC library | **SkyWater sky130hd**, 130 nm, fabricable, `tt_025C_1v80`, NAND2_1 = 3.7536 µm² |

---

## 2. Headline

| | Ascon-AEAD128 | hybrid r=128 | hybrid r=64 |
|---|---|---|---|
| FPGA slices | 355 | 323 (−9.0%) | **271 (−23.7%)** |
| FPGA LUTs | 1101 | 1021 (−7.3%) | **873 (−20.7%)** |
| FPGA registers | 728 | 663 (−8.9%) | **599 (−17.7%)** |
| **FPGA Fmax** | 55.0 MHz | 54.4 MHz | **117.0 MHz** |
| **FPGA throughput** | 880 Mbit/s | 870 Mbit/s | **936 Mbit/s** |
| FPGA energy / bit | 20.5 pJ | **12.7 pJ** | 20.3 pJ |
| sky130 cell area | 46 605 µm² | 41 044 µm² | **36 895 µm²** |
| sky130 gate equivalents | 12 416 GE | 10 935 GE | **9 829 GE (−20.8%)** |
| **sky130 Fmax** | **256 MHz** | 62.5 MHz | 62.5 MHz |
| sky130 throughput | **4.10 Gbit/s** | 1.00 Gbit/s | 0.50 Gbit/s |
| sky130 energy / bit | **21.6 pJ** | 24.9 pJ | 47.4 pJ |
| Capacity (security parameter) | **192 bits** | 128 bits | **192 bits** |

No design wins everywhere. **r=64 is the best FPGA design** — smallest, fastest,
highest throughput, and it has Ascon's capacity. **Ascon is the best ASIC design**
by a wide margin. **r=128 is the most energy-efficient on FPGA.** §7 explains why.

---

## 3. FPGA — Vivado, xc7a12ticsg325-1L

Out-of-context synthesis, then `opt_design → place_design → phys_opt_design →
route_design`. All figures post-route, single-threaded so results are reproducible.

Out-of-context is the standard way to characterise an IP core and is how
published Ascon figures are measured. It is also the only option here: the cores
have more than 400 ports and CSG325 offers roughly 150 usable I/O, so an
I/O-buffered build is not physically possible. Frequencies are therefore for the
core alone and would fall once integrated behind real I/O paths.

### 3.1 Resources

| `report_utilization` | Ascon | r=128 | r=64 |
|---|---|---|---|
| Slice LUTs | 1101 (13.8%) | 1021 (12.8%) | **873 (10.9%)** |
| Slice registers | 728 | 663 | **599** |
| Occupied slices | 355 | 323 | **271** |
| CARRY4 | 15 | 79 | 71 |
| F7 muxes | 56 | 32 | 58 |
| Fully routed nets | 1202 | 974 | 835 |
| Routing errors | 0 | 0 | 0 |

r=64 saves registers mainly on the output path — `dout` is 64 bits wide instead
of 128.

### 3.2 Timing

QoR is **non-monotonic in the constraint** even when deterministic: a tighter
constraint can route better than a looser one. Fmax is therefore the best
achieved period across a search, not a single point.

| | tightest closing constraint | WNS | achieved period | **Fmax** |
|---|---|---|---|---|
| Ascon | 18.384 ns | +0.202 | 18.182 ns | **55.00 MHz** |
| r=128 | 18.960 ns | +0.560 | 18.400 ns | **54.35 MHz** |
| r=64 | **8.719 ns** | +0.174 | **8.545 ns** | **117.03 MHz** |

Critical-path structure, which explains the gap:

| | logic levels | datapath delay | worst hold slack |
|---|---|---|---|
| Ascon | 18 | 19.148 ns | −0.502 ns |
| r=128 | 18 | 19.366 ns | −0.502 ns |
| r=64 | **10** | **9.498 ns** | −0.502 ns |

Ascon and r=128 both sit at 18 logic levels because both are pinned by the same
128-bit padding-mask borrow chain (§7). r=64's rate is 64 bits, so that chain is
half as long — 10 levels — and the design clocks 2.15× faster. The hold figures
are a constraint artefact, see caveat 3.

### 3.3 Power — SAIF-annotated from xsim

Activity captured with the testbench clock set to each design's own closing
period, so the toggle rate matches the constraint.

| | Ascon | r=128 | r=64 |
|---|---|---|---|
| Dynamic | 18 mW | **11 mW** | 19 mW |
| Device static | 57 mW | 57 mW | 57 mW |
| **Total on-chip** | 75 mW | **68 mW** | 76 mW |
| Nets matched by SAIF | 39% (993/2531) | 35% (862/2487) | 27% (605/2208) |
| Vivado confidence | **High** | Medium | Medium |
| Energy per bit | 20.5 pJ | **12.7 pJ** | 20.3 pJ |

Static power is a device property of the XC7A12T, identical for all three.

---

## 4. ASIC — SkyWater sky130 (130 nm, fabricable)

Platform `sky130hd`, corner `tt_025C_1v80` (25 °C, 1.80 V), site `unithd`,
routing met1–met5, floorplan at 45% target utilization, with `repair_design` and
`repair_timing` so the tool actually optimises for the constraint.

### 4.1 Fmax by period sweep

| period | Ascon | r=128 | r=64 |
|---|---|---|---|
| 20.0 ns | — | +3.86 | +2.99 |
| 16.0 ns | — | **+0.03** | **+0.02** |
| 15.0 ns | — | — | −0.35 |
| 14.0 ns | — | −0.97 | — |
| 10.0 ns | +5.70 | — | — |
| 4.4 ns | +0.10 | — | — |
| 4.2 ns | +0.03 | — | — |
| 4.0 ns | +0.01 | — | — |
| 3.9 ns | **+0.00** | — | — |
| 3.8 ns | −0.10 | — | — |

**Ascon closes at 3.9 ns → 256 MHz. Both hybrids close at 16.0 ns → 62.5 MHz.**
All three are now bracketed tightly on both sides — Ascon fails at 3.8 ns, the
hybrids at 15.0 and 14.0 ns.

### 4.2 Parameters at the closing period

| | Ascon @ 3.9 ns | r=128 @ 16.0 ns | r=64 @ 16.0 ns |
|---|---|---|---|
| Cell area (yosys) | 46 604.7 µm² | 41 044.4 µm² | **36 895.4 µm²** |
| Die area | 62 192 µm² @ 60% | 53 839 µm² @ 60% | **47 335 µm² @ 58%** |
| Gate equivalents | 12 416 GE | 10 935 GE | **9 829 GE** |
| Sequential cells | 723 | 659 | **594** |
| Complex combinational | 4606 | 4009 | **3466** |
| Buffers / inverters | 7 | 44 | 66 |
| Clock buffers | 146 | 132 | 110 |
| Timing-repair buffers | 52 | 39 | 34 |
| Setup slack / TNS | +0.00 / 0.00 | +0.03 / 0.00 | +0.02 / 0.00 |
| Hold slack | **+0.14 ns** | **+0.19 ns** | **+0.12 ns** |
| Power (VCD activity) | 88.7 mW | 25.0 mW | 23.7 mW |
| Throughput | **4.10 Gbit/s** | 1.00 Gbit/s | 0.50 Gbit/s |
| Energy per bit | **21.6 pJ** | 24.9 pJ | 47.4 pJ |

Leakage is negligible in this library at this corner (~2 × 10⁻⁸ W), so energy per
bit is essentially frequency-independent and the columns compare directly.

---

## 5. Cycles, throughput and functional verification — Vivado xsim

All three share the FSM, so a block always costs 8 cycles plus one handshake
cycle. Only the block size differs.

```
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

Throughput is 16 bits/cycle for the wide-rate designs and 8 bits/cycle for r=64.

Functional check against the C reference vectors — a 16 × 16 grid of message and
associated-data lengths covering every padding path, each ciphertext fed back
through the decrypt path:

| | encrypt | decrypt |
|---|---|---|
| `ascon_aead128` | 256 / 256 | 256 / 256 |
| `asconsip_aead` | 256 / 256 | 256 / 256 |
| `asconsip64_aead` | 256 / 256 | 256 / 256 |

---

## 6. Where each design wins

**On FPGA, pick r=64.** It is the smallest (−24% slices), the fastest (2.15×),
and has the highest throughput — 936 Mbit/s against 880 for Ascon — *despite*
absorbing half as much data per permutation. The clock more than compensates.
It also has Ascon's 192-bit capacity. There is no axis on which it loses to
r=128 on this fabric.

**On ASIC, pick Ascon.** 256 MHz against 62.5 MHz, 4.1× the throughput, and the
best energy per bit. Its area disadvantage (+26% GE over r=64) does not come
close to paying for an 8× throughput deficit.

**r=128 is the FPGA energy champion** at 12.7 pJ/bit, about 37% better than
either alternative, but it is the only design with a 128-bit capacity — the
weakest security parameter of the three.

**r=64 is the worst ASIC choice**: it clocks no faster than r=128 (both are
bound by SIPROUND, not by the mask) but delivers half the data, so its energy per
bit doubles to 47.4 pJ.

---

## 7. Why FPGA and ASIC disagree

Two different bottlenecks dominate on the two targets.

**On FPGA the bottleneck is the padding mask, not the cipher.** The critical path
is `din_bytes → st_reg`, 18 logic levels of which 15 are CARRY4 — a borrow chain
from

```verilog
wire [127:0] mask = full ? {128{1'b1}} : ((128'd1 << shamt) - 128'd1);
```

The `- 1` is what costs it. This is why Ascon and r=128 land within 1% of each
other (55.0 vs 54.4 MHz) despite completely different round functions: both are
measuring the same mask. **r=64 is the natural experiment** — its rate is 64 bits,
so the same expression builds a 64-bit chain instead of a 128-bit one, logic
levels drop 18 → 10, and the clock doubles. That is the mask being measured, not
the cipher.

A byte-wise decoder removes the chain entirely and would lift all three:

```verilog
genvar gi;
generate
  for (gi = 0; gi < 16; gi = gi + 1) begin : g_lane
    assign mask[gi*8 +: 8] = (gi[4:0] <  din_bytes) ? 8'hff : 8'h00;
    assign padv[gi*8 +: 8] = (gi[4:0] == din_bytes) ? 8'h01 : 8'h00;
  end
endgenerate
```

**On ASIC the mask is cheap**, `repair_timing` optimises it away, and the real
architectural difference appears: Ascon's XOR/AND round collapses to a 3.9 ns
path, while SIPROUND contains **four chained 64-bit additions** that no optimiser
can shorten, holding both hybrids at 16.0 ns regardless of their rate. The 71–79
CARRY4 cells on FPGA and the 16 ns ASIC path are the same phenomenon.

This also confirms the two hybrids share a round function: identical ASIC Fmax,
differing only in area and throughput.

---

## 8. Caveats

1. **Hold on FPGA is a constraint artefact, not a design defect.** The worst hold
   path is `key[116] → k_r_reg[116]/D` — an input port to a register — because
   `set_input_delay 0` gives it no launch delay to absorb. There is not a single
   register-to-register hold violation in any design on any target, and on sky130
   **all three now have positive hold slack** (+0.14 / +0.19 / +0.12 ns).
   Realistic input delays would remove the FPGA artefact too.
2. **SAIF nets matched are 27–39%**, because activity comes from RTL simulation
   while the netlist is post-implementation. Vivado rates Ascon "High" and both
   hybrids "Medium"; r=64 matches fewest because it has the fewest nets. A
   post-implementation timing simulation would raise all three.
3. **ASIC power activity is annotated at top-level ports only** — the VCD is from
   RTL simulation, so only port names match the mapped netlist and OpenSTA
   propagates inward. Gate-level annotation is *possible* on sky130 — SkyWater
   publishes behavioural Verilog models at `google/skywater-pdk-libs-sky130_fd_sc_hd`
   — but that needs another download and a gate-level simulation pass, so it has
   not been done.
4. **The hybrids are unanalysed constructions.** Neither has had cryptanalysis.
   These are engineering measurements, not a security argument.
5. Derived quantities — achieved period (`constraint − WNS`), throughput
   (`bits/cycle × f`), energy per bit (`power ÷ throughput`), gate equivalents
   (`cell area ÷ 3.7536 µm²`) — are arithmetic on the tool outputs above.

---

## 9. Provenance

| Metric | Tool | File |
|---|---|---|
| Functional pass/fail, cycle counts | Vivado xsim | `xsim/xsim_*.log`, `xsim/xs_f_*.log` |
| FPGA utilization, route status | Vivado | `v6/out/*_util.txt`, `*_route.txt` |
| FPGA constraint search, WNS/WHS, logic levels | Vivado | `v6/flow6.out` |
| FPGA critical path | Vivado | `v6/out/*_path.txt` |
| FPGA power (SAIF, period-matched) | Vivado | `v7/out/*_power_saif.txt` |
| FPGA determinism proof | Vivado | `v5/flow5.out` (`DETERMINISM` lines) |
| sky130 period sweep | OpenROAD | `sky/sweep.out`, `sky/r64.out`, `sky/tighten*.out` |
| sky130 area, cells, skew, slack, power | OpenROAD | `sky/{ascon,hybrid,r64,r64v}_*.log` |
| sky130 cell area | yosys | `sky/*_yosys.log` |
| sky130 platform | ORFS | `~/pdks/sky130hd/` (see its `PROVENANCE.md`) |
| Activity source | Vivado xsim | `xsim/f_*.saif`, `xsim/*.vcd` |

Vivado reports carry their own header — tool version, `Device: xc7a12ticsg325-1L`,
`Design State: Routed`, timestamp, host — so each is self-identifying.
