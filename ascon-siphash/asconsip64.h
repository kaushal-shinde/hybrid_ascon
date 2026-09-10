/*
 * Ascon-SipHash-r64 -- experimental hybrid AEAD.
 *
 * WARNING: this is a NEW, UNANALYSED construction. It is not Ascon, it is not
 * SipHash, it is not standardised, and it has had no cryptanalysis. Do not use
 * it to protect anything real. It exists to be studied and attacked.
 *
 *
 * ARCHITECTURE
 * ------------
 * 256-bit state (x0..x3, 64 bits each), round function is Ascon's round
 * constant then SipHash's SIPROUND, same duplex mode. Rate is 64 bits (x0),
 * capacity is 192 bits (x1, x2, x3), block size is 8 bytes, throughput is
 * 64/6 = 10.67 bits/cycle in the round-based hardware.
 *
 * Key, nonce and tag are 128 bits, p^10 for initialisation and finalisation,
 * p^6 per data block, domain separation into x3, the key XORs, byte order --
 * same conventions as Ascon-AEAD128 itself, except the round counts: Ascon
 * uses p^12/p^8, this uses p^10/p^6. That is a deliberate reduction in
 * security margin, taken for throughput, on a construction that has had no
 * cryptanalysis to justify either number. See the WARNING above.
 *
 *
 * DESIGN RATIONALE
 * ----------------
 * Ascon-AEAD128 spends 192 of its 320 state bits on capacity, and generic
 * sponge bounds degrade with c. Holding the rate to 64 bits (x0 alone) keeps
 * that **192-bit capacity of Ascon-AEAD128** in a 256-bit state, at the cost
 * of absorbing only 8 bytes per permutation call.
 *
 * Note this is still *not* Ascon-AEAD128 with a different round: the
 * state is 256 bits rather than 320, so the total of rate plus capacity is 64
 * bits short of Ascon's. It has Ascon's capacity but a smaller state.
 *
 *
 * MODE
 * ----
 *   init      x0 = N0,  x1 = N1,  x2 = K0,  x3 = K1 ^ IV
 *             p^10
 *             x2 ^= K0,  x3 ^= K1
 *   ad        absorb 64-bit blocks into x0, p^6 each, 0x01 padding
 *             (skipped entirely when there is no associated data)
 *   domain    x3 ^= 0x80 << 56
 *   message   XOR into x0, emit ciphertext, p^6, 0x01 padding
 *   final     x2 ^= K0,  x3 ^= K1
 *             p^10
 *             tag = (x2 ^ K0, x3 ^ K1)
 *
 * The IV encodes the rate in the same field Ascon-AEAD128 uses, carrying 8
 * bytes rather than 16.
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
#define ASCONSIP64_PA_ROUNDS 10
#define ASCONSIP64_PB_ROUNDS 6

typedef struct {
  uint64_t x[ASCONSIP64_STATEWORDS];
} asconsip64_state_t;

/* The permutation on its own, for analysis. rounds is clamped to 0..12. */
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
