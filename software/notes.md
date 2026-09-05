# Methodology notes

Companion to `results.csv` and the charts in this folder. See
`../SOFTWARE-RESULTS.md` for the full written report; this file is the
detail reference the chart captions point to.

## Platform

Native x86_64, this machine, GCC 13.3.0, `-O2 -fPIC`. **Not** an embedded
target. No ARM/AVR/RISC-V cross-compiler was installed for this pass (see
the project conversation — installing one was offered and declined in
favor of native profiling). Every number here describes how the official
*reference* C behaves on a desktop CPU, not how a hand-tuned embedded
implementation would behave on a microcontroller. Papers that report
RAM/ROM/cycles for these algorithms almost always target something like
ARM Cortex-M0/M3 or AVR ATmega — expect different absolute numbers there,
though the *relative* ordering between algorithms tends to travel
reasonably well since it's driven by algorithm structure, not platform.

Source: `../ascon-aead128/aead.c`, `../ascon-siphash/asconsip{,64}.c`, and
the reference C in `../lwc-finalists/*/` — the same C this project's
hardware work is transliterated from. Sparkle/Grain/etc.'s KAT/genkat
test-harness files were excluded from the build.

## Column by column

**key_bytes / npub_bytes / tag_bytes** — read at runtime from each
algorithm's own `CRYPTO_KEYBYTES`/`CRYPTO_NPUBBYTES`/`CRYPTO_ABYTES`
(`api.h`), not hand-transcribed.

**input_rate_bytes** — bytes absorbed per core permutation/round-function
call (the algorithm's rate), as documented in this project's own Verilog
transliterations of each algorithm (`../verilog/*.v` headers), cross-checked
against the C reference. Not a runtime measurement — a structural constant.

**rounds** — the permutation round count(s), same source as above. Several
algorithms use more than one count depending on phase (ISAP has four
different round counts for four different sub-protocols; Grain's number is
its initialization length, since "rounds" isn't quite the right frame for a
stream cipher).

**rom_bytes** — `.text` section size (`size` on the compiled `.so`) after
`gcc -O2`. This is code size *as GCC's optimizer chose to lay it out on
x86_64* — table-driven S-boxes, loop unrolling decisions, everything
GCC's inliner/unroller decided is worth it, all differ from what the same
source would produce on an embedded target's much more size-conscious
codegen. Treat this as "how big is the reference implementation," not "how
big would this be on a microcontroller." **Also: `size`'s default "text"
column is a coarser bucket than the actual `.text` ELF section** — see
`rom_dot_text_bytes`/`rom_dot_rodata_bytes` below and `../SOFTWARE-RESULTS.md`
§4.6 for why a large fraction of this number (11-59%, design-dependent) is
shared-library metadata, not code.

**rom_dot_text_bytes / rom_dot_rodata_bytes** — added 2026-09-04: the
*exact* `.text` and `.rodata` ELF section sizes, from `size -A` (Berkeley
per-section listing) rather than the default `size`'s coarser grouping.
`.text` is real executable code; `.rodata` is read-only data — mostly each
algorithm's constant tables (round constants, S-boxes stored as lookup
tables rather than computed, SKINNY's tweakey tables for Romulus, etc.).
Neither is fabricated or estimated — both are `awk '$1==".text"'`/
`'$1==".rodata"'` over `size -A`'s real output, defaulting to 0 for a
design with no `.rodata` section at all (several have none — their tables,
if any, get folded into `.text` as immediate constants or `.data.rel.ro`
by the optimizer instead). `rom_dot_text_bytes + rom_dot_rodata_bytes` is
**not** equal to `rom_bytes` for any of the twelve — the gap is ELF
shared-library bookkeeping (`.dynsym`, `.dynstr`, `.rela.plt`, `.dynamic`,
`.plt`/`.plt.sec`/`.got`, `.eh_frame`/`.eh_frame_hdr`, `.gnu.hash`,
`.gnu.version*`, `.note.*`) that `size`'s default text bucket includes and
this split deliberately excludes — see `../SOFTWARE-RESULTS.md` §4.6 for
the full per-design table and what it means for reading `rom_bytes`.

**ram_bytes** — `.data + .bss` (static/global state only). Deliberately
excludes the call stack, which is reported separately below, since the two
have different real-world implications (RAM is a hard, fixed budget on most
MCUs; stack is a dynamic peak that depends on call depth). It's small and
similar for most of these because AEAD reference code generally keeps its
working state in the *caller's* buffers and locals, not in file-scope
globals — the exceptions (Elephant, PHOTON-Beetle) have larger static
lookup tables.

**stack_bytes** — this is the one metric that needed real debugging to get
right, so it's worth explaining. The first approach was a runtime
"stack-painting" high-water-mark measurement (fill a dedicated pthread
stack with a sentinel byte, run one `encrypt()` call, see how much got
overwritten) — the standard technique for measuring stack use on embedded
targets. On this native x86_64 build it produced the *same* number,
byte-for-byte, for all twelve algorithms — a dead giveaway that something
structural was swamping the signal rather than a genuine coincidence
across twelve unrelated codebases. Root cause: glibc's own per-thread setup
(TLS/TCB placement, `dlopen`'s lazy-binding machinery) touches a fixed
~6.3&nbsp;KB of any custom pthread stack before the algorithm's own code
ever runs, and every one of these AEAD calls uses far less than that on a
16-byte message — so the real per-algorithm signal was a rounding error
against a much larger constant floor.

The fix was to stop measuring at runtime and use the **static** method
instead: GCC's `-fstack-usage` flag emits the exact compiler-computed frame
size of every function (a `.su` file per translation unit); `bench/stackcalc.py`
in this folder parses those
alongside `objdump`'s disassembly to build each algorithm's real call graph
(catching both cross-file calls, which show up as relocations, and
same-file calls, which the assembler resolves directly and therefore leave
no relocation at all — the first version of the script only looked for
relocations and silently undercounted every intra-file call chain, which is
most of them). It then walks the graph from the encrypt entry point and
sums frame sizes along the deepest path. This is the standard way
worst-case stack depth is reported for exactly this kind of "shallow call
tree, no recursion, no dynamic dispatch" embedded-style code — a static
upper bound on the deepest the stack pointer will ever go, which is a more
useful number for someone budgeting an MCU's fixed SRAM than a runtime
sample from one input size on one platform would be anyway.

**latency_cycles** — best-of-20,000 `rdtsc`-measured cycles for one
`encrypt()` call on a 16-byte message with 16 bytes of associated data
(minimum-overhead cost — dominant term is initialization/finalization
rounds, not per-byte work).

**cycles_per_byte / throughput_MBps** — best-of-N timing on a 4096-byte
message with no associated data, so the per-byte cost of the main
processing loop dominates over fixed setup cost. The two are two views of
the same measurement (cross-checked against each other and found
consistent in order of magnitude — `cycles_per_byte × CPU_frequency⁻¹` and
the wall-clock MB/s figure agree to within the clock-rate variation
described next, not to the last digit).

**dec_latency_cycles / dec_cycles_per_byte / dec_throughput_MBps /
dec_roundtrip_ok** — added 2026-09-04: the `decrypt()` counterparts to the
four columns above, same message shapes, same best-of-N methodology,
computed from a real ciphertext (produced by that design's own `encrypt()`
in the immediately preceding measurement, not a hand-built or synthetic
one). `dec_roundtrip_ok` is 1 only if every rep's `decrypt()` call returned
success *and* the recovered plaintext matched the original byte-for-byte;
it is 1 for all twelve designs in this dataset. This checks the benchmark
harness's own `DECRYPT_FN` wiring (`wrap/wrapper.c`, `-DDECRYPT_FN=...` in
`build.sh` for the two hybrids) round-trips correctly — it is not a
substitute for `../RESULTS.md` §1.1's KAT verification of the hardware RTL,
and a `dec_roundtrip_ok` of 1 says nothing about whether the C reference
computes the *cryptographically correct* ciphertext for any input other
than the one it was just handed back.

## Throughput curve (curve_results.csv)

Added 2026-09-04, alongside the single 4096B `cycles_per_byte` point in
`results.csv`: `driver.c` also sweeps message sizes {16, 64, 256, 1024,
4096} bytes, encrypt-only, 0B AD, best-of-200 `rdtsc` per point (fewer reps
than the main 4096B measurement's best-of-300, to keep total runtime
reasonable across 12 designs × 5 sizes — the slowest designs, Elephant and
PHOTON-Beetle, already take real wall-clock minutes at 4096B). Written to
`bench/curve_results.csv` (raw label) and copied to `../curve_results.csv`
(display name, matching `results.csv`'s convention) by `merge.py`. Purpose:
a single 4096B data point can't distinguish "genuinely fast" from "fast
once you amortize a large fixed setup cost over enough bytes" — the curve
can. See `../SOFTWARE-RESULTS.md` §4.7 for what it found (ISAP's fixed
per-call sponge-phase cost dominates dramatically at small message sizes,
far more than any other design here).

## The CPU's actual clock rate, and why it isn't one number

This machine's CPU is an Intel Core i7-6700 (`lscpu`: base 3.40 GHz, max
turbo 4.0 GHz, min 800 MHz) with the **`powersave` governor active**
(`/sys/.../cpufreq/scaling_governor`) — not `performance` — so the core's
actual clock during any given benchmark call depends on the scaling
governor's ramp-up behaviour for that call's load shape, not a single fixed
number. `rdtsc` on this CPU is `constant_tsc`/`nonstop_tsc` (invariant
across P-states), so `latency_cycles`/`cycles_per_byte` are always
TSC-referenced counts, not raw core cycles at whatever frequency the core
happened to be running — but `throughput_MBps` is wall-clock (`clock_gettime`),
which *does* reflect real elapsed time at whatever frequency the core
actually ran at.

Dividing `cycles_per_byte` (TSC ticks) into the wall-clock byte rate
(`cycles_per_byte × throughput_bytes_per_sec`) recovers the **effective TSC
rate implied by that specific design's own measurement** — and it is not
constant: across the twelve designs in the 2026-09-02 dataset this ranges
from **2.79 GHz to 3.87 GHz**, a ~39% spread, tracking each design's own
loop duration/shape (a longer-running design's benchmark window gives the
`powersave` governor more time to ramp up; a fast one may finish before it
does). This is very likely the real mechanism behind the run-to-run
variance flagged in `../SOFTWARE-RESULTS.md` §6 (including the ~32%
Ascon-AEAD128 swing between passes) — not just "background load," but the
governor itself responding differently to each design's own timing profile,
on every single run. `sudo cpupower frequency-set -g performance` (or
equivalent) before a rerun would remove this source of variance if a
tighter cross-design or cross-run comparison is needed; it was not changed
for this dataset in order to measure the machine in its default state.

## What's not here: energy

Real energy measurement needs either RAPL sysfs access
(`/sys/class/powercap/intel-rapl`) or `perf stat -e power/energy-pkg/`,
both of which require root or a relaxed `perf_event_paranoid` on this
machine — currently blocked (`Permission denied` / `perf_event_paranoid
setting is 4`). Neither was enabled for this pass rather than asking for
elevated access mid-task. A rough proxy (cycles × a nominal per-cycle
energy figure) was deliberately **not** fabricated into the CSV, since a
number that looks measured but isn't is worse than an honest gap — see
`../SOFTWARE-RESULTS.md` for how to unblock this if it's wanted later.
