# SipCon64 hybrid AEAD

An experimental AEAD construction built from Ascon's duplex mode with
SipHash's SIPROUND substituted for Ascon's S-box/linear-diffusion round
function. **No dedicated cryptanalysis of this construction has been
performed.** Its security rationale rests on the maturity of the two
components it combines — Ascon's mode and SipHash's round — as argued in
`../paper/related-work.tex`; analysis of the combination itself is future work.

`sipcon64.c` / `.h` shares Ascon-AEAD128's 256-bit state (`x0..x3`, 64
bits each) and the same duplex sponge structure, but replaces Ascon's round
function with SipHash's SIPROUND. Its round schedule is `p^10` for
init/finalisation and `p^6` per data block (`SIPCON64_PA_ROUNDS` /
`SIPCON64_PB_ROUNDS`), reduced from 12/8 on 2026-09-08. Its rate/capacity split is
64/192 bits (rate = `x0`; capacity = `x1`, `x2`, `x3`) — chosen
specifically so the hybrid matches Ascon-AEAD128's own 192-bit capacity,
rather than the 128-bit capacity a naive equal-rate substitution would
give it (see `../RESULTS.md`).

Round function: each round applies Ascon's round-constant addition (same
constant schedule as Ascon-AEAD128) to the state, then runs SIPROUND (from
`../siphash/siphash.c`) in place of Ascon's substitution + linear-diffusion
layers.

Key = 16 bytes, Npub = 16 bytes, tag = 16 bytes — same sizes as
Ascon-AEAD128, following the same eBACS `crypto_aead_encrypt`/`_decrypt`
interface as `../ascon-aead128/`.

Hardware implementation: `../verilog/sipcon64_aead.v` — see
`../verilog/README.md`.
