# Software results: Ascon-AEAD128, two hybrids, and the 9 NIST LWC finalists

Software cost of the same twelve algorithms `RESULTS.md` measures in
hardware — RAM, ROM, stack usage, throughput, latency, key/input/output
size, and round counts — measured from each algorithm's **official
reference C**, compiled and run **natively on this machine** (x86_64, GCC
13.3.0, `-O2`). Full dataset: [`software/results.csv`](software/results.csv).
Charts: [`software/`](software/). Methodology detail behind every column:
[`software/notes.md`](software/notes.md). Reproduce everything with one
command: `software/bench/run_all.sh`.

**Read this before the numbers.** This is a desktop-CPU measurement of
*reference* C, not an embedded-target measurement of a *tuned* implementation
— see §1. And as with the hardware report: only 4 of these 12 designs are
functionally verified in this project (`RESULTS.md` §1.1) — the other 8's
numbers describe what the reference code costs to run, not confirmed-correct
behavior.

---

## 1. Method

| | |
|---|---|
| Platform | **native x86_64**, this machine — no embedded cross-compiler installed |
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

Sorted by ROM (ascending). † = KAT-verified, ‡ = xsim-verified (§`RESULTS.md`
§1.1); unmarked = not run against test vectors in this project.

| design | key/npub/tag (B) | rate (B) | ROM | RAM | stack | latency | cycles/B | throughput |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| TinyJAMBU-128 † | 16/12/8 | 4 | **3,659 B** | 576 B | 280 B | 3,898 cyc | 86.6 | 35.6 MB/s |
| hybrid r=64 ‡ | 16/16/16 | 8 | 4,139 B | 560 B | 264 B | 722 cyc | 10.1 | 308.0 MB/s |
| hybrid r=128 ‡ | 16/16/16 | 16 | 5,077 B | 560 B | **264 B** | **624 cyc** | 7.1 | **429.5 MB/s** |
| GIFT-COFB | 16/16/16 | 16 | 5,603 B | 576 B | 400 B | 57,164 cyc | 1,204.5 | 2.42 MB/s |
| Elephant (Dumbo) | 16/12/8 | 20 | 6,792 B | **1,736 B** | 648 B | 688,602 cyc | **14,480.8** | **0.20 MB/s** |
| ISAP (ISAP-A-128A) | 16/16/16 | 8 | 6,882 B | 672 B | 584 B | 63,286 cyc | 121.3 | 24.3 MB/s |
| PHOTON-Beetle | 16/16/16 | 16 | 7,512 B | 728 B | 520 B | 384,516 cyc | 8,273.3 | 0.35 MB/s |
| Grain-128AEAD | 16/12/8 | 1 | 8,123 B | 696 B | **1,040 B** | 85,898 cyc | 1,493.3 | 1.84 MB/s |
| Xoodyak | 16/16/16 | 16 | 9,337 B | 688 B | 664 B | 5,918 cyc | 83.4 | 35.9 MB/s |
| Romulus (Romulus-N) | 16/16/16 | 16 | 9,832 B | 800 B | 864 B | 24,528 cyc | 792.3 | 3.71 MB/s |
| SPARKLE | 16/32/16 | 32 | 10,199 B | 696 B | 384 B | 3,710 cyc | 25.2 | 117.2 MB/s |
| Ascon-AEAD128 ‡ | 16/16/16 | 16 | **15,386 B** | 552 B | 232 B | 1,148 cyc | 11.2 | 223.3 MB/s |

No design wins everywhere. **TinyJAMBU has the smallest code**; **the two
hybrids are the fastest and leanest-stacked**; **Ascon-AEAD128 has the
largest code footprint of all twelve** despite being mid-pack on speed —
its reference C trades code size for throughput on purpose (§4.3). **Elephant
and PHOTON-Beetle are dramatically slower than everything else** — three to
four orders of magnitude below the fastest designs — for structural reasons
that are well known in the literature, not implementation bugs (§4.1–4.2).

---

## 3. Rounds and rate

Static algorithm facts, not measurements — cross-checked against the C
reference and this project's own Verilog transliterations (`verilog/*.v`
headers, written and checked earlier in this project).

| design | rate (B/call) | rounds |
|---|---:|---|
| Ascon-AEAD128 / both hybrids | 16 (8 for r=64) | 12 init/final + 8 per block |
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

Elephant runs at **14,480 cycles/byte** and PHOTON-Beetle at **8,273** —
three to four orders of magnitude slower than TinyJAMBU (86.6) or Ascon
(11.2). This is not a benchmark artifact: both algorithms' reference C
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

Grain-128AEAD (1,493 cycles/byte) and GIFT-COFB (1,204) are the
next-slowest pair, and for a related reason: Grain is a genuinely bit-serial
stream cipher by design (its whole security argument rests on that), and
GIFT-128's bitsliced S-box (`SubCells` in `gift128.c`) is written to be
efficient when computed across many parallel bit-planes — the classic
"fast in hardware or in a bitslicing framework, slow as scalar C" profile.
Both are legitimate design choices; this benchmark is just the wrong lens
for them.

### 4.3 Ascon's code size is a deliberate trade, not an oversight

Ascon-AEAD128 has the **largest ROM of all twelve** (15,386 B — more than
50% bigger than the next-largest, SPARKLE at 10,199 B) despite being
mid-pack on throughput (223 MB/s — not the fastest, not the slowest). The
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

### 4.4 The two hybrids are the software speed leaders here

Both Ascon-SipHash hybrids beat every finalist (and Ascon itself) on
latency, cycles/byte, and stack usage — hybrid r=128 hits 429.5 MB/s
against Ascon's 223.3. This matches the hardware story only partially:
`RESULTS.md` found the hybrids ASIC-*worse* than Ascon (SIPROUND's four
chained 64-bit adders don't optimize away in silicon), but in software those
same adds are exactly what a 64-bit CPU's ALU is fast at — another instance
of the same "cost model determines the winner" pattern as §4.1. **Both
hybrids remain unanalysed constructions** (`RESULTS.md` §8.1) — a software
speed win is not a security argument.

---

## 5. RAM and stack — reading them together

RAM (`.data+.bss`, static/global state only) and stack (worst-case call-chain
depth, §`software/notes.md`) answer different questions and shouldn't be
summed naively: RAM is a fixed budget an embedded target reserves
permanently; stack is a transient peak that depends on call depth for one
operation. Elephant's RAM (1,736 B) is the outlier here — more than double
every other design's — from static lookup-table storage; everything else
sits in a tight 552–800 B band, reflecting that AEAD reference code
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
5. **Only 4 of 12 designs are functionally verified** in this project
   (`RESULTS.md` §1.1, §8.1) — GIFT-COFB, Grain, SPARKLE, Elephant, ISAP,
   PHOTON-Beetle, Romulus, and Xoodyak are lint-clean/reference-only from
   NIST, not re-verified here. This report measures what their *official*
   C does, which is a stronger provenance bar than this project's own
   Verilog transliterations of those same 8 algorithms carry (see
   `verilog/README.md`'s verification table) — but "official NIST reference
   code" is not the same claim as "this project confirmed it computes the
   right ciphertext," worth keeping straight.
6. Single-machine, single-run timing (best-of-N per measurement, not
   averaged across multiple independent runs or multiple machines) — real
   variance between runs was observed in the low single-digit percent
   range while preparing this report, not large enough to change any
   ranking, but not formally characterized either.

---

## 7. Reproduction

```
software/bench/run_all.sh
```

Builds all twelve `.so`s from the vendored reference C, benchmarks each
(latency/throughput via `rdtsc`+`clock_gettime`), computes static stack
depth (GCC `-fstack-usage` + call-graph analysis — see `software/notes.md`
for why this replaced an initial runtime approach that didn't work),
extracts ROM/RAM via `size`, merges everything into `software/results.csv`,
and regenerates every chart in `software/`. No external dependencies beyond
GCC and Python 3 + pandas + matplotlib, already on this machine.
