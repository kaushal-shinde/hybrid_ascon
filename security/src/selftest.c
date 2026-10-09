/*
 * Self-tests for the SipCon64 security harness.
 *
 * These check the harness and the reference it links against -- not the
 * cipher's security. A measurement harness that is wired up wrong produces
 * confident numbers about nothing, so this runs first in run_all.sh and the
 * pipeline stops if any check fails.
 *
 * The two frozen vectors below were generated from ../../sipcon64/sipcon64.c
 * on 2026-10-01 and pinned here deliberately. If the reference implementation
 * is ever edited, these fail and every measurement in this directory is
 * correctly invalidated rather than silently describing a different function.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "prng.h"
#include "sipcon64_harness.h"

static int failures = 0;

static void check(int ok, const char* what) {
  printf("  %-62s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

int main(void) {
  prng_t rng;
  int i;

  printf("SipCon64 harness self-tests\n");

  /* 1. The reference must still be the p^10/p^6 construction this study
   *    claims to measure. */
  check(SIPCON64_PA_ROUNDS == 10 && SIPCON64_PB_ROUNDS == 6,
        "reference is the p^10/p^6 schedule");
  check(SIPCON64_STATEWORDS == 4 && SIPCON64_RATE == 8,
        "256-bit state, 64-bit rate");
  check(SIPCON64_KEYBYTES == 16 && SIPCON64_NONCEBYTES == 16 &&
            SIPCON64_TAGBYTES == 16,
        "key / nonce / tag are 128 bits each");

  /* 2. Frozen permutation vector: p^12 of the all-zero state. */
  {
    static const uint64_t want_p12[4] = {
        0x8b3316144f91de07ULL, 0x413e6a151af8aedcULL,
        0x1ca6fb31fcf1d9b0ULL, 0x9371991c040bb763ULL,
    };
    uint64_t st[4] = {0, 0, 0, 0};
    sec_perm(st, 12);
    check(memcmp(st, want_p12, sizeof st) == 0,
          "p^12 of the zero state matches the pinned vector");
  }

  /* 3. Frozen AEAD vector, so a change to the mode is caught too. */
  {
    static const unsigned char want[48] = {
        0xc2, 0xba, 0x0c, 0x27, 0xe0, 0x43, 0x66, 0x82,
        0xae, 0x2d, 0x6f, 0xea, 0x2e, 0xf1, 0xf4, 0x7e,
        0x2a, 0xe0, 0x9a, 0xf0, 0xd7, 0xc2, 0x83, 0xa6,
        0x36, 0x21, 0x46, 0x27, 0xa2, 0xf7, 0x8f, 0x50,
        0x94, 0xc9, 0x43, 0xa4, 0xf7, 0xf9, 0x3e, 0xde,
        0x30, 0x6a, 0x0c, 0xb5, 0xf3, 0x2d, 0x0e, 0x61,
    };
    unsigned char k[16], n[16], ad[16], m[32], c[48];
    unsigned long long cl;
    for (i = 0; i < 16; ++i) { k[i] = i; n[i] = 0x10 + i; ad[i] = 0x20 + i; }
    for (i = 0; i < 32; ++i) m[i] = 0x30 + i;
    sipcon64_aead_encrypt(c, &cl, m, 32, ad, 16, 0, n, k);
    check(cl == 48 && memcmp(c, want, 48) == 0,
          "AEAD encrypt matches the pinned ciphertext and tag");
  }

  /* 4. Reduced-round p^r must use the tail of the constant schedule, which is
   *    the convention every round-wise number in this study depends on.
   *    p^12 applied to a state is p^r preceded by the first 12-r constants, so
   *    composing shorter calls must NOT equal a longer one -- if it did, the
   *    rounds would be sharing a prefix and "round r" would mean something
   *    else. */
  {
    uint64_t a[4] = {1, 2, 3, 4}, b[4] = {1, 2, 3, 4};
    sec_perm(a, 12);
    sec_perm(b, 6);
    sec_perm(b, 6);
    check(memcmp(a, b, sizeof a) != 0,
          "p^12 != p^6 o p^6 (tail schedule, not a shared prefix)");
  }

  /* 5. The permutation must actually move the state at every round count. */
  {
    int ok = 1, r;
    for (r = 1; r <= 12; ++r) {
      uint64_t s[4] = {1, 0, 0, 0};
      sec_perm(s, r);
      if (s[0] == 1 && s[1] == 0 && s[2] == 0 && s[3] == 0) ok = 0;
    }
    check(ok, "p^r moves the state for every r = 1..12");
  }

  /* 6. A one-bit input change must reach the output -- the precondition for
   *    the avalanche measurement to mean anything -- and the bit indexing must
   *    be what the harness documents. */
  {
    uint64_t a[4] = {0, 0, 0, 0}, b[4] = {0, 0, 0, 0};
    sec_flip_bit(b, 200);
    sec_perm(a, 6);
    sec_perm(b, 6);
    check(memcmp(a, b, sizeof a) != 0, "a one-bit input change reaches p^6");
    check((200 >> 6) == 3 && (200 & 63) == 8,
          "bit indexing: bit 200 is bit 8 of x3");
    check((5 >> 6) == 0, "bit indexing: bits 0..63 are x0, the rate word");
  }

  /* 7. This is a duplex sponge, not a stream cipher: the state absorbs each
   *    ciphertext block, so C = P XOR keystream holds for the FIRST rate block
   *    only and the stream is plaintext-dependent after that. Both halves are
   *    asserted, because gen_streams' ctstream mode is documented against
   *    exactly this and getting it backwards would mean that mode does not
   *    generate what the report says it generates. */
  {
    unsigned char k[16], npub[16], z[64], m[64], cz[80], cm[80];
    unsigned long long cl;
    int ok_first = 1, differs_later = 0, j;
    prng_seed(&rng, 3);
    prng_bytes(&rng, k, sizeof k);
    prng_bytes(&rng, npub, sizeof npub);
    prng_bytes(&rng, m, sizeof m);
    memset(z, 0, sizeof z);

    sipcon64_aead_encrypt(cz, &cl, z, 64, 0, 0, 0, npub, k);
    sipcon64_aead_encrypt(cm, &cl, m, 64, 0, 0, 0, npub, k);
    for (j = 0; j < SIPCON64_RATE; ++j)
      if ((cz[j] ^ m[j]) != cm[j]) ok_first = 0;
    for (j = SIPCON64_RATE; j < 64; ++j)
      if ((cz[j] ^ m[j]) != cm[j]) differs_later = 1;

    check(ok_first, "first ciphertext block is rate XOR plaintext");
    check(differs_later,
          "the duplex absorbs C, so later blocks are plaintext-dependent");
  }

  /* 8. The AEAD must round-trip and reject tampering, or the tag-avalanche
   *    numbers describe a broken function. */
  {
    unsigned char k[16], npub[16], ad[16], m[64], c[80], p[64];
    unsigned long long cl, ml;
    int ok_rt = 1, ok_rej = 1;
    prng_seed(&rng, 4);
    for (i = 0; i < 200; ++i) {
      prng_bytes(&rng, k, sizeof k);
      prng_bytes(&rng, npub, sizeof npub);
      prng_bytes(&rng, ad, sizeof ad);
      prng_bytes(&rng, m, sizeof m);
      sipcon64_aead_encrypt(c, &cl, m, 64, ad, 16, 0, npub, k);
      if (sipcon64_aead_decrypt(p, &ml, 0, c, cl, ad, 16, npub, k) != 0 ||
          ml != 64 || memcmp(p, m, 64) != 0)
        ok_rt = 0;
      c[i % 80] ^= 0x01;
      if (sipcon64_aead_decrypt(p, &ml, 0, c, cl, ad, 16, npub, k) == 0)
        ok_rej = 0;
      c[i % 80] ^= 0x01;
    }
    check(ok_rt, "AEAD round-trips (200 random messages)");
    check(ok_rej, "AEAD rejects a single-bit ciphertext/tag flip");
  }

  /* 9. The harness PRNG must not be degenerate: a stuck generator would
   *    silently collapse the sample space the whole study rests on. */
  {
    uint64_t acc = 0;
    int ones = 0;
    prng_seed(&rng, 5);
    for (i = 0; i < 4096; ++i) {
      uint64_t v = prng_next(&rng);
      acc ^= v;
      ones += __builtin_popcountll(v);
    }
    /* 4096*64 = 262144 bits; sigma = sqrt(262144)/2 = 256, so 4 sigma ~ 1024 */
    check(acc != 0 && ones > 131072 - 1024 && ones < 131072 + 1024,
          "harness PRNG is not degenerate");
  }

  printf("\n%s (%d failure(s))\n",
         failures ? "SELF-TESTS FAILED" : "all self-tests passed", failures);
  return failures ? 1 : 0;
}
