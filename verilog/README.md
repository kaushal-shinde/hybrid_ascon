# Verilog: Ascon-AEAD128 and the two hybrids

Three hardware cores, one per algorithm in `../ascon-aead128/` and
`../ascon-siphash/`, each a round-based functional twin of its C reference
(one permutation round per clock cycle). All three are the subject of
`../RESULTS.md` (Vivado FPGA + OpenROAD ASIC measurements).

| file | algorithm | state | rate / capacity |
|---|---|---|---|
| `ascon_aead128.v` | Ascon-AEAD128 (NIST SP 800-232) | 320 bits | 128 / 192 |
| `asconsip_aead.v` | Ascon-SipHash hybrid, r=128 | 256 bits | 128 / 128 |
| `asconsip64_aead.v` | Ascon-SipHash hybrid, r=64 | 256 bits | 64 / 192 |

The two hybrids are unanalysed constructions — see
`../ascon-siphash/README.md`.

## Interface

All three share one **custom** block-oriented interface (documented in full
at the top of `ascon_aead128.v`): a one-cycle `start` pulse with `key`/`npub`
held valid, then associated-data blocks (`din_ad = 1`) followed by message
blocks (`din_ad = 0`), each phase terminated by a block with `din_last = 1`
and `din_bytes` giving its real length (0..15, or 0..7 for the r=64 core's
64-bit `din`). Decrypt is latched from `decrypt` at `start`; the core emits
its computed tag on `dout`/`tag` for the host to compare.

**This is not the NIST LWC Hardware API.** The nine cores in
`../verilog-finalists/` use that PDI/SDI/DO word-stream protocol instead —
the two families of cores are not interchangeable or directly comparable at
the port level, only at the algorithm level.

## Verification

Functional correctness for all three was established via Vivado `xsim`
simulation runs, not via the NIST KAT suite (unlike
`../verilog-finalists/tinyjambu_lwc.v`, which is KAT-verified). See
`../RESULTS.md` section 9 ("Provenance") for which log each measurement came
from — those logs themselves are not part of this repo.
