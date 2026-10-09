/*
 * Deterministic PRNG for the SipCon64 security harness
 * (splitmix64 seeding -> xoshiro256**).
 *
 * Every measurement in security/ is seeded, so a rerun with the same seed
 * reproduces the same numbers exactly. This generator only draws the random
 * *inputs* the tests are applied to. It is never the subject of a test, and it
 * never produces a byte of the bitstreams in gen_streams.c -- those come from
 * SipCon64 itself.
 */
#ifndef SEC_PRNG_H_
#define SEC_PRNG_H_

#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint64_t s[4];
} prng_t;

static inline uint64_t splitmix64(uint64_t* x) {
  uint64_t z = (*x += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

static inline void prng_seed(prng_t* r, uint64_t seed) {
  uint64_t x = seed;
  int i;
  for (i = 0; i < 4; ++i) r->s[i] = splitmix64(&x);
}

static inline uint64_t rotl64u(const uint64_t x, int k) {
  return (x << k) | (x >> (64 - k));
}

static inline uint64_t prng_next(prng_t* r) {
  const uint64_t result = rotl64u(r->s[1] * 5, 7) * 9;
  const uint64_t t = r->s[1] << 17;
  r->s[2] ^= r->s[0];
  r->s[3] ^= r->s[1];
  r->s[1] ^= r->s[2];
  r->s[0] ^= r->s[3];
  r->s[2] ^= t;
  r->s[3] = rotl64u(r->s[3], 45);
  return result;
}

static inline void prng_bytes(prng_t* r, unsigned char* p, size_t n) {
  size_t i = 0;
  while (i + 8 <= n) {
    uint64_t v = prng_next(r);
    int j;
    for (j = 0; j < 8; ++j) p[i + j] = (unsigned char)(v >> (8 * j));
    i += 8;
  }
  if (i < n) {
    uint64_t v = prng_next(r);
    while (i < n) {
      p[i] = (unsigned char)v;
      v >>= 8;
      ++i;
    }
  }
}

#endif /* SEC_PRNG_H_ */
