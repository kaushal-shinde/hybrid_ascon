# Ascon-AEAD128, an Ascon-SipHash hybrid, and the NIST LWC finalists

Ascon-AEAD128 (NIST SP 800-232) implemented from the official C reference,
one experimental Ascon/SipHash hybrid AEAD construction, and — for
comparison — C and Verilog implementations of all nine algorithms that lost
to Ascon in the final round of NIST's Lightweight Cryptography competition.
Everything here is either vendored official source or a from-scratch Verilog
transliteration of one; nothing is a new cipher design except the hybrid,
which has had no dedicated cryptanalysis of its own — see
`ascon-siphash/README.md`. All eleven
hardware cores — Ascon, the hybrid, and the nine finalists — live together
in one directory and are measured together in one report, because that is
what they are: Ascon and the field it beat, not two separate projects.

## Layout

```
ascon-aead128/       official Ascon C reference (NIST SP 800-232), vendored
siphash/              official SipHash C reference, vendored
ascon-siphash/        the hybrid AEAD construction (C), see its README
lwc-finalists/        official reference C of the 9 non-winning NIST LWC finalists
verilog/              all 11 hardware cores — Ascon, the hybrid, 9 finalists — see its README
RESULTS.md            Vivado + OpenROAD hardware measurements for all 11 verilog/ cores
graphs/               PNG charts + CSV + Python script for RESULTS.md's data
SOFTWARE-RESULTS.md   native x86_64 software measurements (RAM/ROM/stack/latency/throughput) for all 11
software/             its CSV, charts, methodology notes, and reproducible benchmark harness
```

Each vendored C directory (`ascon-aead128/`, `siphash/`, `lwc-finalists/*/`)
keeps its own upstream README/license; `lwc-finalists/PROVENANCE.md` records
exactly what was fetched from where. `ascon-siphash/` and `verilog/` are
this project's own work and each has a README explaining what's inside and
how thoroughly each core has actually been checked.

## What's verified vs. what's a transliteration

Of the eleven cores in `verilog/`, two (Ascon-AEAD128 and the hybrid)
are functionally verified via Vivado `xsim` against the C reference; the
other nine (`tinyjambu_lwc.v`, `xoodyak_lwc.v`, `giftcofb_lwc.v`,
`grain128aead_lwc.v`, `romulus_n_lwc.v`, `sparkle_lwc.v`, `photonbeetle_lwc.v`,
`elephant_lwc.v`, `isap_lwc.v`) are all verified against the official NIST
KAT vectors — every core in this directory now has an actual simulation
result behind it, not just a lint pass; `verilog/README.md` has the full
per-file breakdown, including the 42 real RTL bugs the KAT runs found and
fixed along the way. Ascon-AEAD128 and the hybrid additionally each have a
KAT-style run of their own (official for Ascon-AEAD128, self-generated for
the hybrid, since no official suite exists for it — `RESULTS.md` §1.1).
`RESULTS.md` reports
Vivado/OpenROAD hardware numbers for all eleven together, with the depth of
measurement (and hence how much to trust each number) called out per design
throughout — read its §1 and §8 before treating any figure as a performance
or security recommendation.

## Interfaces

The eleven cores in `verilog/` do not all share one port convention, and
being in one directory doesn't change that: `ascon_aead128.v` and
`asconsip64_aead.v` implement a custom block-oriented
interface (128-bit or 64-bit wide `din`/`dout`, explicit `din_ad`/
`din_last`), documented at the top of `ascon_aead128.v`; the other nine
implement the NIST LWC Hardware API (GMU CERG PDI/SDI/DO word-stream
protocol) instead. The two are not port-compatible — see `verilog/README.md`
for which is which and why — but they are still one comparison at the
algorithm level, which is what `RESULTS.md` measures.

## Hardware vs. software

`RESULTS.md` measures the eleven Verilog cores; `SOFTWARE-RESULTS.md`
measures the same eleven algorithms' **official reference C**, compiled
natively (no embedded cross-compiler on this machine — see its §1). The two
studies genuinely disagree in places, on purpose: Elephant and PHOTON-Beetle
are unremarkable in hardware but three to four orders of magnitude slower
than everything else in reference software, because both use bit/nibble-
serial operations hardware is good at and a CPU is bad at
(`SOFTWARE-RESULTS.md` §4.1). Read them side by side, not as two votes for
the same answer.
