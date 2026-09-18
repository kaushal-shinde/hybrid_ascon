# Software results: Ascon-AEAD128, an Ascon-SipHash hybrid, and the 9 NIST LWC finalists

Software cost of the same eleven algorithms `RESULTS.md` measures in
hardware — RAM, ROM, stack usage, throughput, latency, key/input/output
size, and round counts — measured from each algorithm's **official
reference C**, compiled and run **natively on this machine** (x86_64, GCC
13.3.0, `-O2`). Full dataset: [`software/results.csv`](software/results.csv).
Charts: [`software/`](software/). Methodology detail behind every column:
[`software/notes.md`](software/notes.md). Reproduce everything with one
command: `software/bench/run_all.sh`.

**Read this before the numbers.** This is a desktop-CPU measurement of
*reference* C, not an embedded-target measurement of a *tuned* implementation
— see §1. And as with the hardware report: 10 of these 11 designs are now
KAT-verified in this project (`RESULTS.md` §1.1) — Ascon-AEAD128 and all 9
NIST finalists pass their official KAT/test-vector suites; only the
Ascon-SipHash hybrid remains unverified against an official suite, because
none exists for it (it is not a NIST submission). This is verification
of the *hardware* RTL against known-answer vectors, not of this software
report's own C measurements — the reference C measured here is what those
KAT vectors were generated from in the first place, so its correctness is
assumed by construction, not separately re-proven in this report.

**The hybrid's round counts changed on 2026-09-08**, from p^12/p^8 to
**p^10/p^6** (`ascon-siphash/asconsip64.h`). Its numbers in this report are
for the new schedule and are **not comparable** with earlier editions — the
other ten designs are unchanged. The reduction was taken for throughput; it
lowers the security margin of a construction that has had no cryptanalysis
to justify either the old counts or the new ones. It also invalidated the
hybrid's self-generated KAT vectors, which were produced from the p^12/p^8
reference — see §1.1 of `RESULTS.md` and the note below.

---

## 1. Method

| | |
|---|---|
| Platform | **native x86_64**, this machine — no embedded cross-compiler installed |
| CPU | Intel Core i7-6700, base 3.40 GHz, max turbo 4.0 GHz, `powersave` governor (not pinned) — see §6 caveat 6 |
| Compiler | GCC 13.3.0, `-O2 -fPIC`, no LTO |
| Source | official reference C: `ascon-aead128/`, `ascon-siphash/`, `lwc-finalists/*/` |
| Harness | `software/bench/` — builds each algorithm as a `.so` behind a uniform `bench_*` ABI, `dlopen()`s each in turn |

This machine has no ARM/AVR/RISC-V cross-compiler, and installing one was
explicitly offered and declined in favor of native profiling (see the
conversation this report came from) — so **every number below describes a
desktop CPU running unmodified reference C**, not the embedded target most
published LWC software benchmarks use. Two consequences worth holding onto
while reading this:

1. **Absolute numbers won't match papers that target an ARM Cortex-M0 or an
   AVR ATmega.** Code size especially: x86_64 `-O2` makes very different
   inlining/unrolling trade-offs than an embedded-tuned build would.
2. **Relative ordering between algorithms travels better than absolute
   numbers do**, because it's driven mostly by algorithm structure (how
   much table lookup vs. bit-twiddling, how many permutation calls, how
   parallel the round function is) rather than by target-specific codegen.
   Where this report's findings line up with published embedded-target
   benchmarks (they do, for the standout cases — §4), that's a real
   cross-check, not a coincidence.

The **reference** implementations here are also not hand-tuned software —
Ascon's own C package is explicitly labelled "highly optimized" and it
shows (§4); several NIST finalists' reference code is deliberately the
simplest correct implementation, not a fast one. This report measures what
NIST's submission packages actually ship, which is what nearly every
academic software comparison of these algorithms also measures.

---

## 2. Headline

Sorted by ROM (ascending). † = KAT-verified against an official suite;
‡ = the hybrid, for which no official suite exists (not a NIST submission)
and whose self-generated vectors were invalidated by the 2026-09-08 round
change — it is now backed only by a directed C-vs-RTL simulation check
(`RESULTS.md` §1.1). Both marks describe the *hardware RTL's* verification
status, carried over for context — see the note above. **Encrypt direction; see §4.5 for decrypt.** Dataset measured
2026-09-08, every column in one harness run (§6 caveat 6's
`powersave`-governor noise applies as always).

| design | key/npub/tag (B) | rate (B) | ROM | RAM | stack | latency | cycles/B | throughput |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| TinyJAMBU-128 † | 16/12/8 | 4 | **3,842 B** | 584 B | 280 B | 3,792 cyc | 84.3 | 37.8 MB/s |
| hybrid r=64 ‡ | 16/16/16 | 8 | 4,322 B | 568 B | 264 B | **634 cyc** | **8.6** | **367.5 MB/s** |
| GIFT-COFB † | 16/16/16 | 16 | 5,794 B | 584 B | 400 B | 49,658 cyc | 1,047.3 | 3.01 MB/s |
| Elephant (Dumbo) † | 16/12/8 | 20 | 6,975 B | **1,744 B** | 648 B | 646,900 cyc | **13,150.5** | **0.24 MB/s** |
| ISAP (ISAP-A-128A) † | 16/16/16 | 8 | 7,065 B | 680 B | 584 B | 68,126 cyc | 124.3 | 24.9 MB/s |
| PHOTON-Beetle † | 16/16/16 | 16 | 7,695 B | 736 B | 520 B | 373,884 cyc | 7,842.9 | 0.40 MB/s |
| Grain-128AEAD † | 16/12/8 | 1 | 8,306 B | 704 B | **1,040 B** | 82,426 cyc | 1,444.9 | 2.16 MB/s |
| Xoodyak † | 16/16/16 | 16 | 9,520 B | 696 B | 664 B | 5,808 cyc | 81.5 | 38.7 MB/s |
| Romulus (Romulus-N) † | 16/16/16 | 16 | 10,095 B | 808 B | 864 B | 23,586 cyc | 740.0 | 4.13 MB/s |
| SPARKLE † | 16/32/16 | 32 | 10,382 B | 704 B | 384 B | 3,632 cyc | 24.7 | 126.0 MB/s |
| Ascon-AEAD128 † | 16/16/16 | 16 | **15,569 B** | 560 B | **232 B** | 1,308 cyc | 10.8 | 277.0 MB/s |

No design wins everywhere. **TinyJAMBU has the smallest code**; **the
hybrid is the fastest** (highest throughput, lowest cycles/byte and
latency); **Ascon-AEAD128 actually has the smallest stack of all eleven**
(232 B) despite having the **largest code footprint of all eleven**
(15,569 B) — its reference C trades code size for throughput on purpose
(§4.3), and its lean stack is a separate, genuinely favorable property this
table makes easy to miss if you only read the "hybrid wins on speed"
headline. **Elephant and PHOTON-Beetle are dramatically slower than
everything else** — three to
four orders of magnitude below the fastest designs — for structural reasons
that are well known in the literature, not implementation bugs (§4.1–4.2).

---

## 3. Rounds and rate

Static algorithm facts, not measurements — cross-checked against the C
reference and this project's own Verilog transliterations (`verilog/*.v`
headers, written and checked earlier in this project).

| design | rate (B/call) | rounds |
|---|---:|---|
| Ascon-AEAD128 | 16 | 12 init/final + 8 per block |
| hybrid r=64 | 8 | 10 init/final + 6 per block |
| TinyJAMBU-128 | 4 | 1024 (key setup) + 640/1152 (per frame) |
| Xoodyak | 16 | 12 (fixed, every permutation call) |
| GIFT-COFB | 16 | 40 (GIFT-128) |
| Grain-128AEAD | 1 | 320 (init) + 256 (key/accumulator load) |
| SPARKLE | 32 | 7 (slim step) / 11 (big step) |
| Elephant (Dumbo) | 20 | 80 (Spongent-π[160]) |
| ISAP (ISAP-A-128A) | 8 | sH=12, sB=1, sE=6, sK=12 (phase-dependent) |
| PHOTON-Beetle | 16 | 12 (PHOTON256) |
| Romulus (Romulus-N) | 16 | 40 (SKINNY-128-384+) |

Grain's "rate" of 1 byte reflects its bit/byte-serial stream-cipher
structure, not a sponge rate — it's not really comparable to the others on
this axis, only listed for completeness.

---

## 4. Findings

### 4.1 Elephant and PHOTON-Beetle are outliers, and that's expected

Elephant runs at **13,150 cycles/byte** and PHOTON-Beetle at **7,843** —
three to four orders of magnitude slower than TinyJAMBU (84.3) or Ascon
(10.8). This is not a benchmark artifact: both algorithms' reference C
implements their permutation in an explicitly bit/nibble-oriented way
(Elephant's Spongent-π[160] pLayer moves individual bits through a
`GET_BIT`/`PUT_BIT`-style formula; PHOTON-Beetle's PHOTON256 round does
repeated GF(16) multiplications cell-by-cell) rather than the word-parallel
operations a CPU is fast at. Both are already known in the published NIST
LWC software-benchmarking literature to be dramatically slower in reference
software than in hardware — this project's own hardware numbers
(`RESULTS.md`) show both as unremarkable-to-competitive on FPGA/ASIC, which
is the expected contrast: bit-serial operations are what dedicated hardware
is *good* at and what a general-purpose CPU is *bad* at. Same algorithm,
opposite verdict, depending which cost model you read.

### 4.2 Grain and GIFT-COFB pay a similar, smaller version of the same tax

Grain-128AEAD (1,444.9 cycles/byte) and GIFT-COFB (1,047.3) are the
next-slowest pair, and for a related reason: Grain is a genuinely bit-serial
stream cipher by design (its whole security argument rests on that), and
GIFT-128's bitsliced S-box (`SubCells` in `gift128.c`) is written to be
efficient when computed across many parallel bit-planes — the classic
"fast in hardware or in a bitslicing framework, slow as scalar C" profile.
Both are legitimate design choices; this benchmark is just the wrong lens
for them.

### 4.3 Ascon's code size is a deliberate trade, not an oversight

Ascon-AEAD128 has the **largest ROM of all eleven** (15,569 B — 50% bigger
than the next-largest, SPARKLE at 10,382 B) despite being mid-pack on
throughput (277.0 MB/s — not the fastest, not the slowest). The
project's own C package describes itself as "reference, **highly
optimized**, masked C and ASM implementations" — this is software written
to be fast and side-channel-resistant, not small, and GCC's `-O2` inliner
happily expands that into more x86_64 code than the more compact
finalist implementations produce. This is worth remembering before reading
"Ascon has the biggest code footprint" as a weakness: it's an artifact of
which reference variant NIST/the Ascon team ship, not a property of the
algorithm's minimum achievable size (`ascon-aead128/README.md` notes this
repository also contains size-optimized and masked variants not vendored
into this project).

### 4.4 The hybrid is the software speed leader here

The Ascon-SipHash hybrid beats every finalist (and Ascon itself) on
latency and cycles/byte — 367.5 MB/s against Ascon's 277.0 — though not on
stack usage, where Ascon-AEAD128 (232 B) is actually leanest of all eleven,
ahead of the hybrid's own 264 B (§2). This matches the hardware story only
partially: `RESULTS.md` found the hybrid ASIC-*worse* than Ascon (SIPROUND's
four chained 64-bit adders don't optimize away in silicon), but in software
those same adds are exactly what a 64-bit CPU's ALU is fast at — another
instance of the same "cost model determines the winner" pattern as §4.1.
**The hybrid has had no dedicated cryptanalysis of its own** (`RESULTS.md`
§8.1) — a software speed win is not a security argument either way.

### 4.5 Decrypt costs about the same as encrypt, for all eleven

Added 2026-09-04, regenerated 2026-09-08:
`dec_latency_cycles`, `dec_cycles_per_byte`,
`dec_throughput_MBps` mirror the existing encrypt columns exactly (same
16B/16B and 4096B/0B message shapes, same best-of-N methodology), and a
correctness check — `decrypt(encrypt(m))` must return success and recover
`m` byte-for-byte — runs before every timed rep. **All eleven passed on
every rep; `dec_roundtrip_ok` is 1 for all eleven** (`software/curve_results.csv`'s
sibling column in `results.csv`) — this is a sanity check on this
benchmark harness's own `DECRYPT_FN` wiring (§`software/notes.md`), not a
re-verification of the algorithms themselves (that's `RESULTS.md` §1.1's
KAT runs against the RTL).

Cost-wise, decrypt tracks encrypt closely for every design — see
[`08_encrypt_vs_decrypt.png`](software/08_encrypt_vs_decrypt.png). On this
run **all eleven are within ±3.1%** (encrypt vs. decrypt cycles/byte) — the
largest gaps are hybrid r=64 (+3.1%, 8.63 → 8.90 cycles/byte) and
Grain-128AEAD (−1.8%, 1,444.9 → 1,419.6); every other design is within ±0.6%.
This is tighter agreement than an earlier pass of this same measurement
showed (up to ±14% on some designs) — consistent with §6 caveat 6's
`powersave`-governor clock-rate noise being the dominant source of those
earlier swings rather than a real encrypt/decrypt asymmetry: this rerun's
tighter spread is itself evidence for that explanation, not against it.
None of these differences, in either pass, are large enough or consistent
enough across reruns to call a real encrypt/decrypt cost asymmetry for any
of the eleven designs.

### 4.6 The "ROM" this report has used is mostly shared-library overhead, not code

This is worth reading carefully: added 2026-09-04, `rom_dot_text_bytes`
and `rom_dot_rodata_bytes` break `rom_bytes` into its real ELF sections
(`size -A`, not the default `size`'s coarser bucket), and doing that
reveals **most of what this report has been calling "ROM" isn't the
algorithm's code at all.** Take Xoodyak: `rom_bytes` = 9,520 B, but
`.text` (real code) is only 4,007 B and `.rodata` (its round-constant
table) is 752 B — **4,761 B, exactly half the reported figure, is
shared-library metadata**: `.dynsym`/`.dynstr`/`.rela.plt`/`.dynamic`
(dynamic-symbol/relocation tables needed only because this harness builds
each algorithm as a `-fPIC -shared` `.so` for `dlopen()`), `.eh_frame`/
`.eh_frame_hdr` (DWARF stack-unwind tables C code doesn't need unless
something throws, which none of this does), `.plt`/`.got` (PLT/GOT
indirection, again a shared-library artifact), and ELF notes/hashes. This
is not a Xoodyak-specific quirk — **the overhead is present in all eleven,
from 11% of `rom_bytes` (Ascon, whose huge inlined `.text` dwarfs the fixed
overhead) up to 59% (Elephant, whose small `.text` doesn't)**:

| design | rom_bytes | .text | .rodata | ELF/shared-lib overhead |
|---|---:|---:|---:|---:|
| Ascon-AEAD128 | 15,569 B | 13,815 B | 0 B | 1,754 B (11%) |
| TinyJAMBU-128 | 3,842 B | 1,671 B | 0 B | 2,171 B (57%) |
| hybrid r=64 | 4,322 B | 2,391 B | 12 B | 1,919 B (44%) |
| GIFT-COFB | 5,794 B | 3,447 B | 40 B | 2,307 B (40%) |
| Grain-128AEAD | 8,306 B | 4,343 B | 16 B | 3,947 B (48%) |
| SPARKLE | 10,382 B | 5,575 B | 288 B | 4,519 B (44%) |
| Elephant (Dumbo) | 6,975 B | 2,887 B | 6 B | **4,082 B (59%)** |
| ISAP (ISAP-A-128A) | 7,065 B | 3,127 B | 279 B | 3,659 B (52%) |
| PHOTON-Beetle | 7,695 B | 3,415 B | 194 B | 4,086 B (53%) |
| Xoodyak | 9,520 B | 4,007 B | 752 B | 4,761 B (50%) |
| Romulus (Romulus-N) | 10,095 B | 3,975 B | 352 B | 5,768 B (57%) |

**What this means for reading this report's own ROM numbers, past and
present:** the `rom_bytes` column (and `04_rom.png`) is *not* corrected
retroactively — it's kept for continuity with everything measured before
2026-09-04 — but it should now be read as a same-machine, same-build-flags
*relative* comparison, not an estimate of real embedded flash cost. A
real embedded build (statically linked, no PIC, no `dlopen()`, almost
certainly `-fno-asynchronous-unwind-tables`) would carry little to none of
this overhead, and `.text + .rodata` is the closer proxy for what would
actually ship — `13,815 + 0 = 13,815 B` for Ascon vs. its `15,569 B`
`rom_bytes`; `2,887 + 6 = 2,893 B` for Elephant vs. its `6,975 B`. The
*relative ordering* between designs is not badly distorted by this (the
overhead is roughly a fixed few KB per `.so` regardless of algorithm, so
it compresses the spread rather than reordering it — TinyJAMBU is still
smallest, Ascon still largest, on either measure), which is why §2's
existing "relative ordering travels better than absolute numbers" caveat
(§1) already covered the right instinct even before this was quantified.
This was not rebuilt with static linking to get a truly clean number
— see §6 caveat 7 for why, and what it would take.

### 4.7 Small messages cost far more per byte than the 4096B figure suggests

Added 2026-09-04: [`07_throughput_curve.png`](software/07_throughput_curve.png)
sweeps 16/64/256/1024/4096-byte messages (encrypt-only, `software/curve_results.csv`)
instead of reporting only the single 4096B point §2's headline table does.
Every design costs more per byte at 16B than at 4096B (fixed per-call setup
amortizes over more bytes as the message grows) — unsurprising in direction,
but **the size of the effect varies enormously by design, and that's the
real finding.** Most designs lose roughly 2-6× per-byte efficiency going from 4096B down
to 16B (SPARKLE, the next-worst, is 6.27×). **ISAP is a dramatic outlier:
33.9× worse at 16B (4,218.8 cycles/byte) than at 4096B (124.5)** — because
ISAP's `sH=12 sB=1 sE=6 sK=12` phase structure
(`RESULTS.md` §5, its own hardware-verified schedule) pays several
expensive fixed-cost sponge phases (key derivation via `sK`, MAC
finalization via `sH`) on *every* call regardless of message length; a
tiny message pays that full fixed cost for almost nothing amortized
against it. This matters directly for anyone choosing an algorithm for a
protocol with small packets — ISAP's mid-pack 4096B throughput (24.9 MB/s,
§2) would badly mislead a decision aimed at short messages, where its
real per-byte cost is closer to Elephant's or PHOTON-Beetle's territory
than to TinyJAMBU's or Xoodyak's, its 4096B neighbors in §2's table.

---

## 5. RAM and stack — reading them together

RAM (`.data+.bss`, static/global state only) and stack (worst-case call-chain
depth, §`software/notes.md`) answer different questions and shouldn't be
summed naively: RAM is a fixed budget an embedded target reserves
permanently; stack is a transient peak that depends on call depth for one
operation. Elephant's RAM (1,744 B) is the outlier here — more than double
every other design's — from static lookup-table storage; everything else
sits in a tight 560–808 B band, reflecting that AEAD reference code
generally keeps its working state in caller-supplied buffers and locals,
not file-scope globals. Grain's stack figure (1,040 B, the largest) comes
from `crypto_aead_encrypt`'s own 592 B frame chained through `init_grain`'s
288 B — both flagged `static` (bounded) by GCC, not `dynamic` — so this is
a real, not an approximate, worst case for the reference code as written.

---

## 6. Caveats

1. **Native x86_64, not an embedded target** — see §1. Don't quote these
   ROM/RAM figures as if they were ARM Cortex-M or AVR numbers.
2. **Reference C, not hand-tuned software** — several of these algorithms
   have faster published software implementations (bitsliced, SIMD,
   platform-specific) that this report doesn't measure. This measures what
   ships in the NIST submission package, which is the common baseline the
   literature also uses, but it is a baseline, not a ceiling.
3. **Energy consumption is not measured.** RAPL (`/sys/class/powercap/intel-rapl`)
   and `perf stat -e power/energy-pkg/` both require root or a relaxed
   `perf_event_paranoid` on this machine (`Permission denied` /
   `perf_event_paranoid setting is 4`); neither was enabled mid-task rather
   than ask for elevated access. A derived proxy (cycles × a nominal
   per-cycle energy figure) was deliberately not fabricated into the
   dataset — see `software/notes.md`. To add real numbers later: `sudo
   sysctl kernel.perf_event_paranoid=1` (session-only) or run
   `software/bench/run_all.sh` under `sudo`, then re-add a `perf stat -e
   power/energy-pkg/` wrapper around the driver.
4. **"RTT" from the original ask was folded into latency** — round-trip
   time is a networking concept; there's no network hop in a standalone
   AEAD call, so it's not reported as a separate column.
5. **10 of 11 designs are now KAT-verified** in this project (`RESULTS.md`
   §1.1, §8.1) — this was originally only 3 (the two Ascon-family designs'
   RTL xsim-checked against their C reference, plus tinyjambu's RTL
   KAT-checked); it is now Ascon-AEAD128 plus all 9 finalists, after fixing
   42 real RTL bugs across 8 finalist cores and running the official KAT
   suite against the fixed RTL (`verilog/README.md`'s verification table).
   Only the Ascon-SipHash hybrid remains unverified against an official
   suite, because none exists for it — it is not a NIST submission,
   only xsim-checked against its own C reference. Worth keeping straight
   regardless: this software report measures the *official reference C*
   directly, which is the source those KAT vectors were generated from in
   the first place — its correctness is assumed by construction here, not
   separately re-proven by this report. What the RTL verification work
   confirms is that this project's own *Verilog transliterations* of these
   algorithms now compute the same answers as that reference C, closing a
   gap that used to exist only for tinyjambu.
6. Single-machine, single-run timing (best-of-N per measurement, not
   averaged across multiple independent runs or multiple machines) — real
   variance between runs was observed in the low single-digit percent
   range while first preparing this report, not large enough to change any
   ranking, but not formally characterized either. On the 2026-09-02
   rerun, most designs again landed within a few percent of the original
   pass, but a handful of `cycles_per_byte`/throughput figures (notably
   Ascon-AEAD128's, ~32% higher) shifted more than that — plausibly because
   this rerun's benchmark executed while unrelated background CPU load
   (filesystem search, other tooling) was active on this 4-core machine,
   which can suppress turbo boost during the best-of-300 sampling window.
   `latency_cycles` (the small fixed-size measurement) was comparatively
   stable; `cycles_per_byte`/throughput (the 4096 B, best-of-300
   measurement) is the more load-sensitive of the two. No ranking or
   qualitative finding in §4 changed. Rerun on an otherwise-idle machine if
   a precise absolute number is needed. **A likely root cause, found
   2026-09-03:** this machine's `powersave` CPU governor is not pinned to a
   fixed frequency, and `cycles_per_byte` × `throughput_MBps` (recovering
   the effective clock rate each design's own measurement implies — see
   `software/notes.md`) is not a fixed number across designs or across
   reruns: it ranged **2.79–3.87 GHz (~39% spread) in the 2026-09-04
   run**, **3.06–3.30 GHz (~7.7% spread) on 2026-09-05**,
   **2.79–3.16 GHz (~13.5% spread) on 2026-09-07**, and **3.15–3.34 GHz
   (~6.1% spread) in the 2026-09-08 rerun**
   — the governor evidently ramps up differently depending on
   each design's own benchmark-loop duration/shape and on ambient system
   load at the time, neither of which is controlled for here. That the
   spread itself varies so much between otherwise-identical reruns is,
   if anything, further evidence for the governor being the mechanism, not
   against it. This affects `cycles_per_byte`/`throughput_MBps`
   specifically (both derived from the same clock-rate-dependent 4096 B
   timing loop); `latency_cycles` is a raw `rdtsc` (TSC-referenced, hence
   `constant_tsc`) count and isn't converted through an assumed frequency,
   so it's unaffected by this specific mechanism.
7. **`rom_bytes` is inflated by shared-library overhead, not just code**
   — see §4.6 for the full breakdown. This harness builds each algorithm
   as a `-fPIC -shared` `.so` so the driver can `dlopen()` it, and that
   choice (needed for the benchmark harness's own design, not a property
   of the algorithms) carries `.dynsym`/`.dynstr`/`.rela.plt`/`.dynamic`/
   `.plt`/`.got`/`.eh_frame` overhead that a statically-linked embedded
   build wouldn't. This wasn't fixed by switching to static linking for
   this pass — doing so would need a real `main()`/linkage per algorithm
   rather than the current uniform `dlopen()`-based harness (a bigger
   change than adding a measurement), and `.text`/`.rodata` from `size -A`
   already give a usable corrected view (§4.6) without it. Worth doing if
   a precise embedded-flash estimate is ever needed from this project.
8. **This dataset has been refreshed several times since**: 2026-09-04 added
   §4.5-§4.7 (decrypt timing, the throughput curve, and the ROM/`.rodata`
   split); 2026-09-05, 2026-09-07 and 2026-09-08 regenerated every number from
   scratch by rerunning the harness across all eleven designs. Every
   deterministic column (ROM, `.text`/`.rodata`, RAM, stack) is
   byte-identical across those reruns; only the timing columns move. Each
   refresh's numbers differ from the previous one by the same
   few-percent, `powersave`-governor-driven noise caveat 6 already
   describes, not a new effect each time.

---

## 7. Reproduction

```
software/bench/run_all.sh
```

Builds all eleven `.so`s from the vendored reference C, benchmarks each —
encrypt *and* decrypt latency/throughput via `rdtsc`+`clock_gettime`, plus
a decrypt round-trip correctness check (§4.5) and an encrypt-only
multi-size throughput curve (§4.7, `software/curve_results.csv`) — computes
static stack depth (GCC `-fstack-usage` + call-graph analysis — see
`software/notes.md` for why this replaced an initial runtime approach that
didn't work), extracts ROM/RAM via `size` plus a `.text`/`.rodata` split via
`size -A` (§4.6), merges everything into `software/results.csv`, and
regenerates every chart in `software/`, including
[`07_throughput_curve.png`](software/07_throughput_curve.png) and
[`08_encrypt_vs_decrypt.png`](software/08_encrypt_vs_decrypt.png). No
external dependencies beyond GCC and Python 3 + pandas + matplotlib,
already on this machine.
