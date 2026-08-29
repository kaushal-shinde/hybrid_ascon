# Verilog: Ascon-AEAD128, the two hybrids, and the 9 NIST LWC finalists

Twelve hardware AEAD cores in one directory: Ascon-AEAD128, the two
Ascon-SipHash hybrids (`../ascon-siphash/`), and one core per algorithm that
lost to Ascon in the final round of NIST's Lightweight Cryptography
competition (`../lwc-finalists/`). All twelve are measured together in
`../RESULTS.md` — this is one comparison, not two.

| file | algorithm | key / npub / tag (bytes) |
|---|---|---|
| `ascon_aead128.v` | Ascon-AEAD128 (NIST SP 800-232, the winner) | 16 / 16 / 16 |
| `asconsip_aead.v` | Ascon-SipHash hybrid, r=128 (unanalysed) | 16 / 16 / 16 |
| `asconsip64_aead.v` | Ascon-SipHash hybrid, r=64 (unanalysed) | 16 / 16 / 16 |
| `tinyjambu_lwc.v` | TinyJAMBU-128 | 16 / 12 / 8 |
| `xoodyak_lwc.v` | Xoodyak | 16 / 16 / 16 |
| `giftcofb_lwc.v` | GIFT-COFB | 16 / 16 / 16 |
| `grain128aead_lwc.v` | Grain-128AEAD | 16 / 12 / 8 |
| `sparkle_lwc.v` | SPARKLE (Schwaemm256-128) | 16 / 32 / 16 |
| `elephant_lwc.v` | Elephant (Dumbo) | 16 / 12 / 8 |
| `isap_lwc.v` | ISAP (ISAP-A-128A) | 16 / 16 / 16 |
| `photonbeetle_lwc.v` | PHOTON-Beetle | 16 / 16 / 16 |
| `romulus_n_lwc.v` | Romulus (Romulus-N) | 16 / 16 / 16 |

`ascon_aead128.v`, `asconsip_aead.v` and `asconsip64_aead.v` are functional
twins of the C in `../ascon-aead128/` and `../ascon-siphash/`. The other nine
are transliterations of the reference C vendored in `../lwc-finalists/`,
whose own `PROVENANCE.md` records where and when each was fetched from NIST.
The two hybrids are unanalysed constructions — see `../ascon-siphash/README.md`.

## Two interfaces, one comparison

These twelve cores were not all built to the same port convention, and
merging them into one directory doesn't erase that — it's a real fact about
how they were built, not filing:

- **`ascon_aead128.v`, `asconsip_aead.v`, `asconsip64_aead.v`** share a
  **custom** block-oriented interface (documented in full at the top of
  `ascon_aead128.v`): a one-cycle `start` pulse with `key`/`npub` held valid,
  then associated-data blocks (`din_ad = 1`) followed by message blocks
  (`din_ad = 0`), each phase terminated by a block with `din_last = 1` and
  `din_bytes` giving its real length. Decrypt is latched from `decrypt` at
  `start`; the core emits its computed tag on `dout`/`tag`.
- **The other nine** all implement the **NIST LWC Hardware API** (GMU CERG
  PDI/SDI/DO word-stream protocol — the same convention the real NIST
  hardware competition used to benchmark every finalist, Ascon included):
  32-bit `valid`/`ready` word streams, instruction opcodes
  (`ENC`/`DEC`/`LDKEY`/`ACTKEY`), and 32-bit segment headers (type,
  partial/eoi/eot/last flags, 16-bit length).

**The two are not interchangeable or directly comparable at the port
level** — only at the algorithm level (area, timing, power — see
`../RESULTS.md`). Each file's header states which interface it uses.

## Verification status — read this before trusting a result

| file(s) | status |
|---|---|
| `ascon_aead128.v`, `asconsip_aead.v`, `asconsip64_aead.v` | functionally verified via Vivado `xsim` simulation (not against the NIST KAT suite) |
| `tinyjambu_lwc.v` | **KAT-verified**: passes the full official test vector suite in simulation (17127/17127 words) |
| the other 8 finalist files | lint-clean in both Verilator and Vivado (`xvlog`); **not run against KAT vectors in simulation** |

The eight non-KAT-verified finalist cores are careful, structurally-reasoned
transliterations — several had real logic bugs caught and fixed by hand
during review (byte-order mismatches, off-by-one block boundaries, a
mis-indexed matrix in Romulus's SKINNY ShiftRows) — but "lint-clean" only
means the tools accept the Verilog; it does not mean the cipher is computed
correctly. Treat any result from these eight as unverified until an actual
KAT run says otherwise. Each file's own header names the exact reference
source it was transliterated from and documents every non-obvious design
decision made along the way (byte-order conventions, padding edge cases,
capacity limits where relevant).

## Results

`../RESULTS.md` covers all twelve cores together — Vivado FPGA
(xc7a12ticsg325-1L) and OpenROAD ASIC (sky130hd) area, timing and power —
with the depth of measurement noted per design (the original three got a
full period sweep and simulation-derived power annotation; the nine
finalists got a lighter single-pass survey). See its §1 for exactly what
differs and why, and its caveats section before treating any number as a
security or performance recommendation.
