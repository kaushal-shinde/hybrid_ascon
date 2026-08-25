# Hardware results: Ascon-AEAD128 vs the Ascon-SipHash hybrid

Area, timing and power for the two AEAD cores in [`verilog/`](verilog/).

**Every number was produced by Xilinx Vivado or by OpenROAD** on this machine.
Section 8 maps each metric to the log it came from. Measured 2026-08-25.

---

## 1. Tools and target

| | |
|---|---|
| FPGA implementation | Vivado v2026.1, `set_param general.maxThreads 1` |
| FPGA part | **xc7a12ticsg325-1L** — Artix-7, CSG325, speed grade -1L, 8000 LUTs / 16000 FFs |
| Simulation | Vivado `xvlog` / `xelab` / `xsim` |
| ASIC P&R, optimisation, STA, power | OpenROAD 2.0-12381-g01bba3695 |
| ASIC synthesis front-end | yosys 0.38+92 (OpenROAD does not synthesise) |
| ASIC library | Nangate45, NAND2_X1 = 0.798 µm² |

---

## 2. Headline

| | Ascon-AEAD128 | Ascon-SipHash hybrid |
|---|---|---|
| FPGA slices | 356 | **323** (−9.3%) |
| FPGA LUTs | 1101 | **1021** (−7.3%) |
| FPGA Fmax | **55.0 MHz** | 54.4 MHz |
| ASIC area (timing-optimised) | 12 518 µm² / 15 687 GE | **10 846 µm² / 13 591 GE** (−13.4%) |
| **ASIC Fmax** | **≥ 714 MHz** | 167 MHz |
| ASIC power @ 100 MHz | **16.4 mW** | 18.3 mW |
| FPGA energy / bit | 20.3 pJ | **13.0 pJ** |
| ASIC energy / bit @ 100 MHz | **10.2 pJ** | 11.5 pJ |

The hybrid is smaller on both targets and cheaper per bit on FPGA. On ASIC it is
**4× slower** and slightly worse per bit. See §6 for why the two targets disagree.

---

## 3. FPGA — Vivado, xc7a12ticsg325-1L

Out-of-context synthesis (the cores have more ports than CSG325 has pins), then
`opt_design → place_design → phys_opt_design → route_design`. All post-route.

### 3.1 Resources

| `report_utilization` | Ascon | Hybrid |
|---|---|---|
| Slice LUTs | 1101 (13.8%) | **1021 (12.8%)** |
| Slice registers | 728 | **663** |
| Occupied slices | 356 | **323** |
| CARRY4 | 15 | 79 |
| F7 muxes | 56 | 32 |
| Fully routed nets | 1188 | 974 |
| Nets with routing errors | 0 | 0 |

### 3.2 Timing

**Implementation is now reproducible.** `general.maxThreads` defaults to 8, which
is what made two identical runs disagree by up to 0.40 ns previously. Pinned to 1,
each operating point was implemented twice and produced **bit-identical slack**:

| | constraint | run 1 WNS | run 2 WNS | identical |
|---|---|---|---|---|
| Ascon | 19.063 ns | +0.668 | +0.668 | yes |
| Hybrid | 18.960 ns | +0.560 | +0.560 | yes |

**QoR is non-monotonic in the constraint**, even deterministically — a tighter
constraint can route better than a looser one, because the constraint changes
placement decisions. Fmax is therefore taken as the best achieved period across a
constraint sweep, not from a single point:

| Ascon constraint | WNS | achieved | Hybrid constraint | WNS | achieved |
|---|---|---|---|---|---|
| 19.525 | +1.121 | 18.404 | 19.673 | +0.810 | 18.863 |
| 19.400 | −0.105 | — | 19.584 | −0.069 | — |
| 19.063 | +0.668 | 18.395 | 18.960 | +0.560 | **18.400** |
| **18.384** | **+0.202** | **18.182** | 18.843 | −0.097 | — |
| 18.375 | −0.688 | — | 18.380 | −0.794 | — |
| 18.162 | −0.881 | — | | | |

**Fmax: Ascon 55.00 MHz** (18.182 ns), **hybrid 54.35 MHz** (18.400 ns).

Other timing parameters, at the reported operating point:

| | Ascon | Hybrid |
|---|---|---|
| Worst hold slack (WHS) | −0.502 ns | −0.502 ns |
| Logic levels on the critical path | 18 | 18 |
| Datapath delay | 19.361 ns | 19.366 ns |

The hold violations are an out-of-context artefact: input delay is set to zero, so
pad-to-register paths have no launch delay to absorb. They are not a defect in the
cores and would disappear with realistic input delays.

### 3.3 Power — SAIF-annotated from xsim

| | Ascon | Hybrid |
|---|---|---|
| Clocks / logic / signals | 4 / 6 / 7 mW | 3 / 4 / 4 mW |
| **Dynamic** | 17 mW | **11 mW** |
| Device static | 57 mW | 57 mW |
| **Total on-chip** | 74 mW | **68 mW** |
| Junction temperature | 25.4 °C | 25.4 °C |
| Nets matched by SAIF | 39% (993/2531) | 35% (862/2487) |
| Vivado confidence | **High** | Medium |
| Energy per bit | 20.3 pJ | **13.0 pJ** |

Static power is a device property of the XC7A12T, identical for both.

---

## 4. ASIC — OpenROAD, Nangate45

This pass runs `repair_design` and `repair_timing`, which the earlier pass did
not. That is what makes an ASIC Fmax meaningful: without optimisation the tool
never tries to meet the constraint, and the reported slack understates the design.

### 4.1 Fmax by period sweep

Setup slack against constrained period, timing-optimised:

| period | Ascon | Hybrid |
|---|---|---|
| 10.0 ns | +8.73 | +4.94 |
| 8.0 ns | +6.67 | +2.91 |
| 6.0 ns | +4.72 | **+0.92** |
| 5.0 ns | +3.70 | — |
| 4.0 ns | +2.64 | — |
| 3.0 ns | +1.66 | — |
| 2.0 ns | +0.64 | — |
| 1.6 ns | +0.27 | — |
| 1.4 ns | **+0.07** | — |

**Ascon closes at 1.4 ns → ≥ 714 MHz.** **Hybrid closes at 6.0 ns → 167 MHz.**
Ascon's critical path is ~1.33 ns; the hybrid's is ~5.08 ns.

### 4.2 Parameters at the closing period

| | Ascon @ 1.4 ns | Hybrid @ 6.0 ns |
|---|---|---|
| Die area | 12 489 µm² @ 87% | 10 846 µm² @ 87% |
| Sequential cells | 723 | 659 |
| Complex combinational cells | 4141 | 3705 |
| Buffers / inverters | 291 | 164 |
| Clock buffers | 106 | 98 |
| Timing-repair buffers | 53 | 45 |
| Setup slack / TNS | +0.07 / 0.00 | +0.92 / 0.00 |
| Hold slack | −0.71 ns | −0.11 ns |
| Clock latency | 0.24 ns | 0.25 ns |
| Power (VCD activity) | 114.3 mW | 30.3 mW |
| Throughput | 11.43 Gbit/s | 2.67 Gbit/s |
| Energy per bit | **10.0 pJ** | 11.4 pJ |

### 4.3 At a common 100 MHz

| | Ascon | Hybrid |
|---|---|---|
| Die area | 12 518 µm² | **10 846 µm²** |
| Gate equivalents | 15 687 GE | **13 591 GE** |
| Setup slack | +8.73 ns | +4.94 ns |
| Hold slack | −0.18 ns | −0.12 ns |
| Power, default activity | 18.2 mW | 20.3 mW |
| Power, VCD activity | **16.4 mW** | 18.3 mW |
| Energy per bit | **10.2 pJ** | 11.5 pJ |

### 4.4 What timing optimisation costs

| | area without | area with | change | Ascon critical path |
|---|---|---|---|---|
| Ascon | 9509 µm² | 12 518 µm² | **+31.6%** | 12.08 ns → **1.33 ns** |
| Hybrid | 8302 µm² | 10 846 µm² | **+30.6%** | 5.18 ns → 5.08 ns |

Ascon gains almost tenfold in speed for a third more area. The hybrid gains almost
nothing, because its critical path is arithmetic, not mapping — see §6.

---

## 5. Cycles, throughput and functional verification — Vivado xsim

Both cores share the FSM, so cycle counts are identical.

```
initialisation            12 cycles   (p^12)
per associated-data block  8 cycles   (p^8)
per message block          8 cycles   (p^8, except the last)
finalisation              12 cycles   (p^12)
```

| message / AD | cycles |
|---|---|
| 0 B / 0 B | 29 |
| 0 B / 16 B | 47 |
| 0 B / 32 B | 56 |
| 0 B / 64 B | 74 |
| 16 B / 64 B | 83 |
| 64 B / 64 B | 110 |

Steady state is 8 cycles per 128-bit block plus one handshake cycle, so each extra
16-byte block costs 9 cycles and long-message throughput is 16 bits per cycle.

Functional check against the C reference vectors, 16 × 16 grid of message and
associated-data lengths covering every padding path, each ciphertext fed back
through the decrypt path:

| | encrypt | decrypt |
|---|---|---|
| `ascon_aead128` | 256 / 256 | 256 / 256 |
| `asconsip_aead` | 256 / 256 | 256 / 256 |

---

## 6. Why the two targets disagree, and where the hybrid actually loses

On FPGA the two cores are within 1% of each other (55.0 vs 54.4 MHz). On ASIC
Ascon is more than four times faster. Both facts have the same cause.

On **FPGA**, both cores are limited by the same thing, and it is not the cipher.
The critical path is:

```
Source:            din_bytes[2]
Destination:       st_reg[248]/D
Logic Levels:      18  (CARRY4=15  LUT4=1  LUT5=2)
```

Fifteen chained CARRY4 cells — a 128-bit borrow chain from the padding mask:

```verilog
wire [127:0] mask = full ? {128{1'b1}} : ((128'd1 << shamt) - 128'd1);
```

The `- 1` is what costs it. Because this path dominates both designs equally,
their FPGA frequencies are nearly identical and say nothing about the round
functions. A byte-wise decoder removes the chain entirely:

```verilog
genvar gi;
generate
  for (gi = 0; gi < 16; gi = gi + 1) begin : g_lane
    assign mask[gi*8 +: 8] = (gi[4:0] <  din_bytes) ? 8'hff : 8'h00;
    assign padv[gi*8 +: 8] = (gi[4:0] == din_bytes) ? 8'h01 : 8'h00;
  end
endgenerate
```

Measured previously on this variant: CARRY4 15 → 0, logic levels 18 → 3, Ascon
Fmax ~52 → ~250–270 MHz, hybrid ~54 → ~130 MHz. *(Those figures come from the
earlier non-deterministic runs and are kept for the shape of the result, not the
digits. The fix is not applied to `verilog/`.)*

On **ASIC** the mask is cheap, so `repair_timing` optimises it away and the real
difference appears immediately: Ascon's round is XOR/AND and collapses to 1.33 ns;
the hybrid's SIPROUND contains **four chained 64-bit additions** that no optimiser
can shorten, holding it at 5.08 ns. The 64 CARRY4 cells on FPGA and the 5.08 ns
ASIC path are the same phenomenon.

**This corrects an earlier reading.** Without timing optimisation the two appeared
tied on ASIC. They are not — Ascon is roughly 4× faster once the tools are allowed
to optimise. The hybrid's real advantages are area (−13%) and FPGA energy per bit
(−36%), not speed.

---

## 7. Caveats

1. **ASIC Fmax is a lower bound.** Ascon is confirmed to close at 1.4 ns; runs
   below that did not finish within the time allowed, so the true limit may be
   tighter. The hybrid is bracketed between 6.0 ns (closes) and 5.0 ns (untested).
2. **Hold violations are present** on both targets. On FPGA they are an
   out-of-context artefact of zero input delay. On ASIC (−0.71 / −0.11 ns) they
   are real and would need fixing before tapeout; they do not affect the setup,
   area or power figures reported here.
3. **SAIF nets matched are 35–40%**, because activity is captured from RTL
   simulation while the netlist is post-implementation. Vivado rates Ascon "High"
   confidence and the hybrid "Medium". A post-implementation timing simulation
   would raise both.
4. **ASIC power activity is annotated at top-level ports only** — the VCD is from
   RTL simulation, so only port names match the mapped netlist, and OpenSTA
   propagates inward. Gate-level annotation would need Nangate45 Verilog cell
   models, which are not on this machine.
5. **Fmax is out-of-context**, for the core alone. Integrated with real I/O paths
   both numbers fall. This is inherent: the cores have more than 400 ports and
   CSG325 offers ~150 usable I/O, so an in-context implementation is impossible
   without a serialising wrapper that would measure a different circuit.
6. Derived quantities — achieved period (`constraint − WNS`), throughput
   (`16 bits × f`), energy per bit (`power ÷ throughput`), gate equivalents
   (`area ÷ 0.798 µm²`) — are arithmetic on the tool outputs above.

---

## 8. Provenance

| Metric | Tool | File |
|---|---|---|
| Functional pass/fail, cycle counts | Vivado xsim | `xsim/xsim_ascon.log`, `xsim/xsim_hybrid.log` |
| FPGA utilization, route status | Vivado | `v5/out/*_util.txt`, `*_route.txt` |
| FPGA constraint sweep, determinism | Vivado | `v5/flow5.out` (`SEARCH`, `DETERMINISM`) |
| FPGA WNS/WHS, logic levels, datapath | Vivado | `v5/flow5.out` (`FINAL`), `v5/out/*_timing.txt` |
| FPGA critical path | Vivado | `v5/out/*_paths_setup.txt` |
| FPGA power (SAIF) | Vivado | `v5/out/*_power_saif.txt` |
| ASIC period sweep | OpenROAD | `a3/sweep.out`, `a3/sweep_lo.out` |
| ASIC area, cells, skew, slack, power | OpenROAD | `a3/{ascon,hybrid}_*.log` |
| ASIC area without optimisation | OpenROAD | `a2/*_or.log` |
| ASIC cell area | yosys | `a2/*_yosys.log` |
| Activity source | Vivado xsim | `xsim/*.saif`, `xsim/*.vcd` |

Vivado reports carry their own header — tool version, `Device: xc7a12ticsg325-1L`,
`Design State: Routed`, timestamp, host — so each is self-identifying.
