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
big would this be on a microcontroller."

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
consistent — `cycles_per_byte × CPU_frequency⁻¹` and the wall-clock MB/s
figure agree).

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
