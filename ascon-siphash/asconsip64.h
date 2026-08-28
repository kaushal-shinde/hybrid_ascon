/*
 * Ascon-SipHash-r64 -- experimental hybrid AEAD, narrow-rate variant.
 *
 * WARNING: this is a NEW, UNANALYSED construction. It is not Ascon, it is not
 * SipHash, it is not standardised, and it has had no cryptanalysis. Do not use
 * it to protect anything real. It exists to be studied and attacked.
 *
 *
 * RELATIONSHIP TO asconsip.h
 * --------------------------
 * Identical architecture. Same 256-bit state, same round function (Ascon's
 * round constant then SipHash's SIPROUND), same round counts, same duplex mode,
 * same initialisation and finalisation. **Only the state configuration differs:
 * where the rate ends and the capacity begins.**
 *
 *                        asconsip.h            this file
 *   state                256 bits              256 bits
 *   rate                 128 bits  (x0, x1)    **64 bits  (x0)**
 *   capacity             128 bits  (x2, x3)    **192 bits (x1, x2, x3)**
 *   block                16 bytes              **8 bytes**
 *   throughput           16 bits/cycle         **8 bits/cycle**
 *
 * Everything else -- key, nonce and tag at 128 bits, p^12 for initialisation
 * and finalisation, p^8 per data block, domain separation into x3, the key
 * XORs, byte order -- is unchanged.
 *
 *
 * WHY THIS VARIANT EXISTS
 * -----------------------
 * The 128-bit capacity is the sharpest edge on the wide-rate version: Ascon-
 * AEAD128 spends 192 bits on capacity, and generic sponge bounds degrade with
 * c. Narrowing the rate to 64 bits moves those 64 bits into the capacity and
 * **restores the 192-bit capacity of Ascon-AEAD128**, at the cost of halving
 * the data absorbed per permutation call.
 *
 * That is the whole trade: same silicon, same clock, half the throughput, and
 * the security parameter that was below Ascon's is brought back up to it.
 *
 * Note this variant is still *not* Ascon-AEAD128 with a different round: the
 * state is 256 bits rather than 320, so the total of rate plus capacity is 64
 * bits short of Ascon's. It has Ascon's capacity but a smaller state.
 *
 *
 * MODE
 * ----
 *   init      x0 = N0,  x1 = N1,  x2 = K0,  x3 = K1 ^ IV
 *             p^12
 *             x2 ^= K0,  x3 ^= K1
 *   ad        absorb 64-bit blocks into x0, p^8 each, 0x01 padding
 *             (skipped entirely when there is no associated data)
 *   domain    x3 ^= 0x80 << 56
 *   message   XOR into x0, emit ciphertext, p^8, 0x01 padding
 *   final     x2 ^= K0,  x3 ^= K1
 *             p^12
 *             tag = (x2 ^ K0, x3 ^ K1)
 *
 * The IV encodes the rate, so a state of this variant can never collide with
 * one of the wide-rate variant: they are separated by construction.
 *
 * Bytes are loaded and stored little-endian, matching both the Ascon SP 800-232
 * reference code and SipHash.
 */
#ifndef ASCONSIP64_H_
#define ASCONSIP64_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ASCONSIP64_KEYBYTES 16
#define ASCONSIP64_NONCEBYTES 16
#define ASCONSIP64_TAGBYTES 16
#define ASCONSIP64_RATE 8
#define ASCONSIP64_STATEWORDS 4
#define ASCONSIP64_PA_ROUNDS 12
#define ASCONSIP64_PB_ROUNDS 8

typedef struct {
  uint64_t x[ASCONSIP64_STATEWORDS];
} asconsip64_state_t;

/* The permutation on its own, for analysis. Identical to the wide-rate
 * variant's; rounds is clamped to 0..12. */
void asconsip64_permutation(asconsip64_state_t* s, int rounds);

/* c receives mlen + ASCONSIP64_TAGBYTES bytes. nsec is unused, pass NULL. */
int asconsip64_aead_encrypt(unsigned char* c, unsigned long long* clen,
                            const unsigned char* m, unsigned long long mlen,
                            const unsigned char* ad, unsigned long long adlen,
                            const unsigned char* nsec,
                            const unsigned char* npub, const unsigned char* k);

/* Returns 0 if the tag verifies, -1 otherwise. On failure the contents of m
 * are unspecified and must not be used. */
int asconsip64_aead_decrypt(unsigned char* m, unsigned long long* mlen,
                            unsigned char* nsec, const unsigned char* c,
                            unsigned long long clen, const unsigned char* ad,
                            unsigned long long adlen,
                            const unsigned char* npub, const unsigned char* k);

#ifdef __cplusplus
}
#endif

#endif /* ASCONSIP64_H_ */
