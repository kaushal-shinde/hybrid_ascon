# Verilog: the 9 non-winning NIST LWC finalists

One hardware core per algorithm in `../lwc-finalists/`, each a careful
transliteration of that algorithm's official reference C, sharing one
interface across all nine: the **NIST Lightweight Cryptography Hardware
API** (GMU CERG PDI/SDI/DO word-stream protocol — the same convention the
real NIST hardware competition used), *not* the custom interface used by
`../verilog/`'s three cores.

**None of these won** — Ascon did. They exist for hardware comparison
against `../verilog/ascon_aead128.v`, not as a recommendation. None has been
through the Vivado/OpenROAD measurement flow that produced `../RESULTS.md`.

## Files and provenance

| file | algorithm | `../lwc-finalists/` source | key / npub / tag (bytes) |
|---|---|---|---|
| `tinyjambu_lwc.v` | TinyJAMBU-128 | `tinyjambu/` | 16 / 12 / 8 |
| `xoodyak_lwc.v` | Xoodyak | `xoodyak/` | 16 / 16 / 16 |
| `giftcofb_lwc.v` | GIFT-COFB | `gift-cofb/` | 16 / 16 / 16 |
| `grain128aead_lwc.v` | Grain-128AEAD | `grain-128aead/` | 16 / 12 / 8 |
| `sparkle_lwc.v` | SPARKLE (Schwaemm256-128) | `sparkle/` | 16 / 32 / 16 |
| `elephant_lwc.v` | Elephant (Dumbo) | `elephant/` | 16 / 12 / 8 |
| `isap_lwc.v` | ISAP (ISAP-A-128A) | `isap/` | 16 / 16 / 16 |
| `photonbeetle_lwc.v` | PHOTON-Beetle | `photon-beetle/` | 16 / 16 / 16 |
| `romulus_n_lwc.v` | Romulus (Romulus-N) | `romulus/` | 16 / 16 / 16 |

Each file's own header names the exact reference source file(s) it was
transliterated from and documents every non-obvious design decision made
along the way (byte-order conventions, padding edge cases, capacity limits
where relevant). `../lwc-finalists/PROVENANCE.md` records where and when
each algorithm's official C package was fetched from NIST.

## Verification status — read this before trusting one of these

| file | status |
|---|---|
| `tinyjambu_lwc.v` | **KAT-verified**: passes the full official test vector suite in simulation (17127/17127 words) |
| all other 8 files | lint-clean in both Verilator and Vivado (`xvlog`); **not run against KAT vectors in simulation** |

The eight non-KAT-verified cores are careful, structurally-reasoned
transliterations — several had real logic bugs caught and fixed by hand
during review (byte-order mismatches, off-by-one block boundaries, a
mis-indexed matrix in Romulus's SKINNY ShiftRows) — but "lint-clean" only
means the tools accept the Verilog; it does not mean the cipher is computed
correctly. Treat any result from these eight as unverified until an actual
KAT run says otherwise.

## Interface

PDI (plaintext/AD in), SDI (key in), DO (ciphertext/tag/status out), all
32-bit word streams with `valid`/`ready` handshakes, NIST LWC instruction
opcodes (`ENC`/`DEC`/`LDKEY`/`ACTKEY`) and 32-bit segment headers (type,
partial/eoi/eot/last flags, 16-bit length) — see any file's header comment
for the full port list and the exact opcode/segment-type encoding used.
