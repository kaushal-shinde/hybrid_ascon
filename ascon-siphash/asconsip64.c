/*
 * Ascon-SipHash-r64 -- experimental hybrid AEAD, narrow-rate variant.
 * See asconsip64.h for the design and for why this must not be used to protect
 * anything real.
 *
 * Same architecture as asconsip.c; the rate is 64 bits instead of 128, so data
 * is absorbed into x0 alone and x1 joins the capacity.
 */
#include "asconsip64.h"

/* ---------------------------------------------------------------- bytes --- */

#define GETBYTE(x, i) ((uint8_t)((uint64_t)(x) >> (8 * (i))))
#define SETBYTE(b, i) ((uint64_t)(b) << (8 * (i)))
#define PAD(i) SETBYTE(0x01, i)
#define DSEP() SETBYTE(0x80, 7)

static uint64_t LOADBYTES(const uint8_t* bytes, int n) {
  int i;
  uint64_t x = 0;
  for (i = 0; i < n; ++i) x |= SETBYTE(bytes[i], i);
  return x;
}

static void STOREBYTES(uint8_t* bytes, uint64_t x, int n) {
  int i;
  for (i = 0; i < n; ++i) bytes[i] = GETBYTE(x, i);
}

static uint64_t CLEARBYTES(uint64_t x, int n) {
  int i;
  for (i = 0; i < n; ++i) x &= ~SETBYTE(0xff, i);
  return x;
}

/* ------------------------------------------------------------ permutation - */

#define ROTL64(x, b) (uint64_t)(((x) << (b)) | ((x) >> (64 - (b))))

static const uint8_t ASCONSIP64_RC[12] = {0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5,
                                          0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b};

static void asconsip64_round(asconsip64_state_t* s, uint8_t C) {
  uint64_t v0 = s->x[0];
  uint64_t v1 = s->x[1];
  uint64_t v2 = s->x[2] ^ (uint64_t)C;
  uint64_t v3 = s->x[3];

  v0 += v1;
  v1 = ROTL64(v1, 13);
  v1 ^= v0;
  v0 = ROTL64(v0, 32);
  v2 += v3;
  v3 = ROTL64(v3, 16);
  v3 ^= v2;
  v0 += v3;
  v3 = ROTL64(v3, 21);
  v3 ^= v0;
  v2 += v1;
  v1 = ROTL64(v1, 17);
  v1 ^= v2;
  v2 = ROTL64(v2, 32);

  s->x[0] = v0;
  s->x[1] = v1;
  s->x[2] = v2;
  s->x[3] = v3;
}

void asconsip64_permutation(asconsip64_state_t* s, int rounds) {
  int i;
  if (rounds < 0) rounds = 0;
  if (rounds > 12) rounds = 12;
  for (i = 12 - rounds; i < 12; ++i) asconsip64_round(s, ASCONSIP64_RC[i]);
}

#define PA(s) asconsip64_permutation((s), ASCONSIP64_PA_ROUNDS)
#define PB(s) asconsip64_permutation((s), ASCONSIP64_PB_ROUNDS)

/* --------------------------------------------------------------- the IV ---
 * Same encoding as the wide-rate variant, but the rate field holds 8 instead
 * of 16, so the two constructions can never share a state. */

#define ASCONSIP64_IV                                 \
  (((uint64_t)(1) << 0) |            /* AEAD    */    \
   ((uint64_t)(ASCONSIP64_PA_ROUNDS) << 16) |         \
   ((uint64_t)(ASCONSIP64_PB_ROUNDS) << 20) |         \
   ((uint64_t)(ASCONSIP64_TAGBYTES * 8) << 24) |      \
   ((uint64_t)(ASCONSIP64_RATE) << 40) |              \
   ((uint64_t)(0x53) << 48))         /* 'S': SipHash round core */

static void asconsip64_init(asconsip64_state_t* s, uint64_t K0, uint64_t K1,
                            const unsigned char* npub) {
  s->x[0] = LOADBYTES(npub, 8);
  s->x[1] = LOADBYTES(npub + 8, 8);
  s->x[2] = K0;
  s->x[3] = K1 ^ ASCONSIP64_IV;
  PA(s);
  s->x[2] ^= K0;
  s->x[3] ^= K1;
}

static void asconsip64_absorb_ad(asconsip64_state_t* s, const unsigned char* ad,
                                 unsigned long long adlen) {
  if (adlen) {
    while (adlen >= ASCONSIP64_RATE) {
      s->x[0] ^= LOADBYTES(ad, 8);
      PB(s);
      ad += ASCONSIP64_RATE;
      adlen -= ASCONSIP64_RATE;
    }
    s->x[0] ^= LOADBYTES(ad, (int)adlen);
    s->x[0] ^= PAD(adlen);
    PB(s);
  }
  s->x[3] ^= DSEP();
}

int asconsip64_aead_encrypt(unsigned char* c, unsigned long long* clen,
                            const unsigned char* m, unsigned long long mlen,
                            const unsigned char* ad, unsigned long long adlen,
                            const unsigned char* nsec,
                            const unsigned char* npub, const unsigned char* k) {
  asconsip64_state_t s;
  const uint64_t K0 = LOADBYTES(k, 8);
  const uint64_t K1 = LOADBYTES(k + 8, 8);

  (void)nsec;
  *clen = mlen + ASCONSIP64_TAGBYTES;

  asconsip64_init(&s, K0, K1, npub);
  asconsip64_absorb_ad(&s, ad, adlen);

  /* full plaintext blocks */
  while (mlen >= ASCONSIP64_RATE) {
    s.x[0] ^= LOADBYTES(m, 8);
    STOREBYTES(c, s.x[0], 8);
    PB(&s);
    m += ASCONSIP64_RATE;
    c += ASCONSIP64_RATE;
    mlen -= ASCONSIP64_RATE;
  }
  /* final plaintext block */
  s.x[0] ^= LOADBYTES(m, (int)mlen);
  STOREBYTES(c, s.x[0], (int)mlen);
  s.x[0] ^= PAD(mlen);
  c += mlen;

  /* finalize */
  s.x[2] ^= K0;
  s.x[3] ^= K1;
  PA(&s);
  s.x[2] ^= K0;
  s.x[3] ^= K1;

  STOREBYTES(c, s.x[2], 8);
  STOREBYTES(c + 8, s.x[3], 8);
  return 0;
}

int asconsip64_aead_decrypt(unsigned char* m, unsigned long long* mlen,
                            unsigned char* nsec, const unsigned char* c,
                            unsigned long long clen, const unsigned char* ad,
                            unsigned long long adlen,
                            const unsigned char* npub, const unsigned char* k) {
  asconsip64_state_t s;
  uint8_t t[ASCONSIP64_TAGBYTES];
  const uint64_t K0 = LOADBYTES(k, 8);
  const uint64_t K1 = LOADBYTES(k + 8, 8);
  int i;
  int result = 0;

  (void)nsec;
  if (clen < ASCONSIP64_TAGBYTES) return -1;
  *mlen = clen - ASCONSIP64_TAGBYTES;

  asconsip64_init(&s, K0, K1, npub);
  asconsip64_absorb_ad(&s, ad, adlen);

  /* full ciphertext blocks */
  clen -= ASCONSIP64_TAGBYTES;
  while (clen >= ASCONSIP64_RATE) {
    uint64_t c0 = LOADBYTES(c, 8);
    STOREBYTES(m, s.x[0] ^ c0, 8);
    s.x[0] = c0;
    PB(&s);
    m += ASCONSIP64_RATE;
    c += ASCONSIP64_RATE;
    clen -= ASCONSIP64_RATE;
  }
  /* final ciphertext block */
  {
    uint64_t c0 = LOADBYTES(c, (int)clen);
    STOREBYTES(m, s.x[0] ^ c0, (int)clen);
    s.x[0] = CLEARBYTES(s.x[0], (int)clen);
    s.x[0] |= c0;
    s.x[0] ^= PAD(clen);
  }
  c += clen;

  /* finalize */
  s.x[2] ^= K0;
  s.x[3] ^= K1;
  PA(&s);
  s.x[2] ^= K0;
  s.x[3] ^= K1;

  STOREBYTES(t, s.x[2], 8);
  STOREBYTES(t + 8, s.x[3], 8);

  for (i = 0; i < ASCONSIP64_TAGBYTES; ++i) result |= c[i] ^ t[i];
  result = (((result - 1) >> 8) & 1) - 1;
  return result;
}
