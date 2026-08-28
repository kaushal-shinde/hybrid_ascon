# Ascon-SipHash hybrid AEAD

Two experimental AEAD constructions built from Ascon's duplex mode with
SipHash's SIPROUND substituted for Ascon's S-box/linear-diffusion round
function. **Unanalysed constructions — no cryptanalysis has been done on
either. These are engineering exercises, not a security recommendation.**

Both share the same 256-bit state (`x0..x3`, 64 bits each), the same 12/8
round schedule as Ascon-AEAD128 (`p^12` for init/finalisation, `p^8` per data
block), and the same duplex sponge structure. They differ only in where the
rate/capacity split falls:

| | `asconsip.c` / `.h` | `asconsip64.c` / `.h` |
|---|---|---|
| rate | 128 bits (`x0`, `x1`) | 64 bits (`x0`) |
| capacity | 128 bits (`x2`, `x3`) | 192 bits (`x1`, `x2`, `x3`) |
| matches Ascon-AEAD128's capacity? | no (Ascon: 192) | **yes** |

The r=64 variant exists specifically to restore Ascon-AEAD128's 192-bit
capacity while keeping the SipHash-based round function, isolating the
effect of rate width alone when comparing the two hybrids' hardware cost
(see `../RESULTS.md`).

Round function: each round applies Ascon's round-constant addition (same
constant schedule as Ascon-AEAD128) to the state, then runs SIPROUND (from
`../siphash/siphash.c`) in place of Ascon's substitution + linear-diffusion
layers.

Key = 16 bytes, Npub = 16 bytes, tag = 16 bytes — same sizes as
Ascon-AEAD128, following the same eBACS `crypto_aead_encrypt`/`_decrypt`
interface as `../ascon-aead128/`.

Hardware implementations of both: `../verilog/asconsip_aead.v` (r=128) and
`../verilog/asconsip64_aead.v` (r=64) — see `../verilog/README.md`.
