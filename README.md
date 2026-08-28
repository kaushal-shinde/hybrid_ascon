# Ascon-AEAD128, an Ascon-SipHash hybrid, and the NIST LWC finalists

Ascon-AEAD128 (NIST SP 800-232) implemented from the official C reference,
two experimental Ascon/SipHash hybrid AEAD constructions, and — for
comparison — C and Verilog implementations of all nine algorithms that lost
to Ascon in the final round of NIST's Lightweight Cryptography competition.
Everything here is either vendored official source or a from-scratch Verilog
transliteration of one; nothing is a new cipher design except the two
hybrids, which are unanalysed and not a security recommendation.

## Layout

```
ascon-aead128/       official Ascon C reference (NIST SP 800-232), vendored
siphash/              official SipHash C reference, vendored
ascon-siphash/        the two hybrid AEAD constructions (C), see its README
lwc-finalists/        official reference C of the 9 non-winning NIST LWC finalists
verilog/              3 hardware cores: Ascon, and the two hybrids — see its README
verilog-finalists/    9 hardware cores, one per finalist — see its README
RESULTS.md            Vivado + OpenROAD measurements for the 3 verilog/ cores
```

Each vendored C directory (`ascon-aead128/`, `siphash/`, `lwc-finalists/*/`)
keeps its own upstream README/license; `lwc-finalists/PROVENANCE.md` records
exactly what was fetched from where. `ascon-siphash/`, `verilog/` and
`verilog-finalists/` are this project's own work and each has a README
explaining what's inside and, for the Verilog cores, how thoroughly each one
has actually been checked.

## What's verified vs. what's a transliteration

- The **3 cores in `verilog/`** (Ascon-AEAD128 and both hybrids) are the ones
  `RESULTS.md` reports Vivado/OpenROAD numbers for. See `verilog/README.md`.
- Of the **9 cores in `verilog-finalists/`**, only `tinyjambu_lwc.v` has been
  run against the official KAT vectors in simulation. The other eight are
  lint-clean in both Verilator and Vivado but not simulation-verified — each
  file's header says so, and `verilog-finalists/README.md` has the full
  breakdown. None of the 9 has hardware measurements (no `RESULTS.md`
  equivalent).

## Interfaces

`verilog/`'s three cores share one custom block-oriented interface (128-bit
or 64-bit wide `din`/`dout`, explicit `din_ad`/`din_last`) documented at the
top of `verilog/ascon_aead128.v`. `verilog-finalists/`'s nine cores instead
all implement the NIST LWC Hardware API (GMU CERG PDI/SDI/DO word-stream
protocol) — the two are not interchangeable; see each directory's README.
