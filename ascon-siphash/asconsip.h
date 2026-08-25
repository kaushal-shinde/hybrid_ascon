/*
 * Ascon-SipHash -- an experimental hybrid AEAD.
 *
 * WARNING: this is a NEW, UNANALYSED construction. It is not Ascon, it is not
 * SipHash, it is not standardised, and it has had no cryptanalysis. Do not use
 * it to protect anything real. It exists to be studied and attacked.
 *
 *
 * DESIGN
 * ------
 * Ascon's duplex mode, shrunk to a 4-word state, with Ascon's substitution and
 * linear layers replaced by SipHash's round function.
 *
 *   state       256 bits, 4 x 64-bit words x0..x3  (Ascon uses 5 words / 320 bits)
 *   rate        128 bits, words x0, x1
 *   capacity    128 bits, words x2, x3             (Ascon-AEAD128 uses 192)
 *   key         128 bits
 *   nonce       128 bits
 *   tag         128 bits
 *   p^a         12 rounds, used for initialisation and finalisation
 *   p^b          8 rounds, used per data block
 *
 * The 4-word state is what makes the graft fit: SIPROUND is defined over
 * exactly four 64-bit words (v0..v3), so it drops onto x0..x3 unchanged.
 *
 * Round function -- Ascon's round constant, then SIPROUND verbatim:
 *
 *   x2 ^= C_r
 *   x0 += x1;  x1 = ROTL(x1,13);  x1 ^= x0;  x0 = ROTL(x0,32)
 *   x2 += x3;  x3 = ROTL(x3,16);  x3 ^= x2
 *   x0 += x3;  x3 = ROTL(x3,21);  x3 ^= x0
 *   x2 += x1;  x1 = ROTL(x1,17);  x1 ^= x2;  x2 = ROTL(x2,32)
 *
 * SIPROUND supplies both nonlinearity (addition mod 2^64) and diffusion (the
 * rotations), so Ascon's linear layer is dropped rather than stacked on top.
 * The round constant goes into x2, a capacity word, so it never interacts
 * directly with absorbed data. Constants are Ascon's own schedule; p^n uses the
 * last n of the twelve, exactly as Ascon does.
 *
 * Mode -- Ascon-AEAD128's duplex, with one forced change. Ascon initialises
 * with IV || K || N, which needs 320 bits; only 256 are available here, so the
 * IV is folded into the key word instead of occupying a word of its own:
 *
 *   init      x0 = N0,  x1 = N1,  x2 = K0,  x3 = K1 ^ IV
 *             p^12
 *             x2 ^= K0,  x3 ^= K1
 *   ad        absorb 128-bit blocks into (x0,x1), p^8 each, 0x01 padding
 *             (skipped entirely when there is no associated data)
 *   domain    x3 ^= 0x80 << 56
 *   message   XOR into (x0,x1), emit ciphertext, p^8, 0x01 padding
 *   final     x2 ^= K0,  x3 ^= K1
 *             p^12
 *             tag = (x2 ^ K0, x3 ^ K1)
 *
 * Bytes are loaded and stored little-endian, which is what both the Ascon
 * SP 800-232 reference code and SipHash already use, so no conversion is
 * needed at the seam.
 *
 *
 * SECURITY NOTE
 * -------------
 * The 128-bit capacity is the sharpest edge. Ascon-AEAD128 spends 192 bits on
 * capacity for a reason: generic sponge bounds degrade with c, and at c = 128
 * the birthday bound on the capacity sits at 2^64. Keyed-duplex bounds are
 * better than the plain indifferentiability bound, but this is unambiguously a
 * weaker parameter set than the algorithm it is derived from -- that is a
 * consequence of the 4-word / 128-bit-capacity requirement, not an oversight.
 *
 * Separately, SIPROUND diffuses more slowly per round than Ascon's S-box and
 * linear layer together, and SipHash's own 2-round/4-round pacing assumes a
 * secret state with a 64-bit output, not a sponge exposing 128 bits of rate per
 * block. Ascon's 12/8 pacing is used here as the more conservative of the two.
 */
#ifndef ASCONSIP_H_
#define ASCONSIP_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ASCONSIP_KEYBYTES 16
#define ASCONSIP_NONCEBYTES 16
#define ASCONSIP_TAGBYTES 16
#define ASCONSIP_RATE 16
#define ASCONSIP_STATEWORDS 4
#define ASCONSIP_PA_ROUNDS 12
#define ASCONSIP_PB_ROUNDS 8

typedef struct {
  uint64_t x[ASCONSIP_STATEWORDS];
} asconsip_state_t;

/* The permutation on its own, for analysis. rounds is clamped to 0..12 and
 * consumes the last `rounds` constants of Ascon's schedule. */
void asconsip_permutation(asconsip_state_t* s, int rounds);

/* c receives mlen + ASCONSIP_TAGBYTES bytes. nsec is unused, pass NULL.
 * Returns 0. */
int asconsip_aead_encrypt(unsigned char* c, unsigned long long* clen,
                          const unsigned char* m, unsigned long long mlen,
                          const unsigned char* ad, unsigned long long adlen,
                          const unsigned char* nsec, const unsigned char* npub,
                          const unsigned char* k);

/* Returns 0 if the tag verifies, -1 otherwise. On failure the contents of m
 * are unspecified and must not be used. */
int asconsip_aead_decrypt(unsigned char* m, unsigned long long* mlen,
                          unsigned char* nsec, const unsigned char* c,
                          unsigned long long clen, const unsigned char* ad,
                          unsigned long long adlen, const unsigned char* npub,
                          const unsigned char* k);

#ifdef __cplusplus
}
#endif

#endif /* ASCONSIP_H_ */
