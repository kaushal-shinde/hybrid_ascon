/*
 * Ascon-SipHash -- experimental hybrid AEAD. See asconsip.h for the design and
 * for why this must not be used to protect anything real.
 *
 * The duplex mode below follows the structure of the Ascon-AEAD128 reference
 * implementation (ascon/ascon-c, CC0), reduced from five words to four. The
 * round function is SipHash's SIPROUND (veorq/SipHash, CC0/MIT/Apache-2.0).
 */
#include "asconsip.h"

/* ---------------------------------------------------------------- bytes ---
 * Little-endian, the convention used by both the Ascon SP 800-232 reference
 * code and SipHash. */

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

/* Ascon's round constant schedule; p^n uses the last n entries. */
static const uint8_t ASCONSIP_RC[12] = {0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5,
                                        0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b};

/* Ascon's constant addition, then SIPROUND in place of the S-box and linear
 * layer. */
static void asconsip_round(asconsip_state_t* s, uint8_t C) {
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

void asconsip_permutation(asconsip_state_t* s, int rounds) {
  int i;
  if (rounds < 0) rounds = 0;
  if (rounds > 12) rounds = 12;
  for (i = 12 - rounds; i < 12; ++i) asconsip_round(s, ASCONSIP_RC[i]);
}

#define PA(s) asconsip_permutation((s), ASCONSIP_PA_ROUNDS)
#define PB(s) asconsip_permutation((s), ASCONSIP_PB_ROUNDS)

/* --------------------------------------------------------------- the IV ---
 * Parameter encoding, laid out like Ascon's but with a marker byte so a state
 * of this construction can never coincide with an Ascon one. */

#define ASCONSIP_IV                                 \
  (((uint64_t)(1) << 0) |            /* AEAD    */  \
   ((uint64_t)(ASCONSIP_PA_ROUNDS) << 16) |         \
   ((uint64_t)(ASCONSIP_PB_ROUNDS) << 20) |         \
   ((uint64_t)(ASCONSIP_TAGBYTES * 8) << 24) |      \
   ((uint64_t)(ASCONSIP_RATE) << 40) |              \
   ((uint64_t)(0x53) << 48))         /* 'S': SipHash round core */

/* Shared initialisation: nonce into the rate, key into the capacity, IV folded
 * into the last key word because there is no spare word to hold it. */
static void asconsip_init(asconsip_state_t* s, uint64_t K0, uint64_t K1,
                          const unsigned char* npub) {
  s->x[0] = LOADBYTES(npub, 8);
  s->x[1] = LOADBYTES(npub + 8, 8);
  s->x[2] = K0;
  s->x[3] = K1 ^ ASCONSIP_IV;
  PA(s);
  s->x[2] ^= K0;
  s->x[3] ^= K1;
}

static void asconsip_absorb_ad(asconsip_state_t* s, const unsigned char* ad,
                               unsigned long long adlen) {
  if (adlen) {
    /* full associated data blocks */
    while (adlen >= ASCONSIP_RATE) {
      s->x[0] ^= LOADBYTES(ad, 8);
      s->x[1] ^= LOADBYTES(ad + 8, 8);
      PB(s);
      ad += ASCONSIP_RATE;
      adlen -= ASCONSIP_RATE;
    }
    /* final associated data block */
    if (adlen >= 8) {
      s->x[0] ^= LOADBYTES(ad, 8);
      s->x[1] ^= LOADBYTES(ad + 8, (int)(adlen - 8));
      s->x[1] ^= PAD(adlen - 8);
    } else {
      s->x[0] ^= LOADBYTES(ad, (int)adlen);
      s->x[0] ^= PAD(adlen);
    }
    PB(s);
  }
  /* domain separation */
  s->x[3] ^= DSEP();
}

int asconsip_aead_encrypt(unsigned char* c, unsigned long long* clen,
                          const unsigned char* m, unsigned long long mlen,
                          const unsigned char* ad, unsigned long long adlen,
                          const unsigned char* nsec, const unsigned char* npub,
                          const unsigned char* k) {
  asconsip_state_t s;
  const uint64_t K0 = LOADBYTES(k, 8);
  const uint64_t K1 = LOADBYTES(k + 8, 8);

  (void)nsec;
  *clen = mlen + ASCONSIP_TAGBYTES;

  asconsip_init(&s, K0, K1, npub);
  asconsip_absorb_ad(&s, ad, adlen);

  /* full plaintext blocks */
  while (mlen >= ASCONSIP_RATE) {
    s.x[0] ^= LOADBYTES(m, 8);
    s.x[1] ^= LOADBYTES(m + 8, 8);
    STOREBYTES(c, s.x[0], 8);
    STOREBYTES(c + 8, s.x[1], 8);
    PB(&s);
    m += ASCONSIP_RATE;
    c += ASCONSIP_RATE;
    mlen -= ASCONSIP_RATE;
  }
  /* final plaintext block */
  if (mlen >= 8) {
    s.x[0] ^= LOADBYTES(m, 8);
    s.x[1] ^= LOADBYTES(m + 8, (int)(mlen - 8));
    STOREBYTES(c, s.x[0], 8);
    STOREBYTES(c + 8, s.x[1], (int)(mlen - 8));
    s.x[1] ^= PAD(mlen - 8);
  } else {
    s.x[0] ^= LOADBYTES(m, (int)mlen);
    STOREBYTES(c, s.x[0], (int)mlen);
    s.x[0] ^= PAD(mlen);
  }
  c += mlen;

  /* finalize */
  s.x[2] ^= K0;
  s.x[3] ^= K1;
  PA(&s);
  s.x[2] ^= K0;
  s.x[3] ^= K1;

  /* tag */
  STOREBYTES(c, s.x[2], 8);
  STOREBYTES(c + 8, s.x[3], 8);

  return 0;
}

int asconsip_aead_decrypt(unsigned char* m, unsigned long long* mlen,
                          unsigned char* nsec, const unsigned char* c,
                          unsigned long long clen, const unsigned char* ad,
                          unsigned long long adlen, const unsigned char* npub,
                          const unsigned char* k) {
  asconsip_state_t s;
  uint8_t t[ASCONSIP_TAGBYTES];
  const uint64_t K0 = LOADBYTES(k, 8);
  const uint64_t K1 = LOADBYTES(k + 8, 8);
  int i;
  int result = 0;

  (void)nsec;
  if (clen < ASCONSIP_TAGBYTES) return -1;
  *mlen = clen - ASCONSIP_TAGBYTES;

  asconsip_init(&s, K0, K1, npub);
  asconsip_absorb_ad(&s, ad, adlen);

  /* full ciphertext blocks */
  clen -= ASCONSIP_TAGBYTES;
  while (clen >= ASCONSIP_RATE) {
    uint64_t c0 = LOADBYTES(c, 8);
    uint64_t c1 = LOADBYTES(c + 8, 8);
    STOREBYTES(m, s.x[0] ^ c0, 8);
    STOREBYTES(m + 8, s.x[1] ^ c1, 8);
    s.x[0] = c0;
    s.x[1] = c1;
    PB(&s);
    m += ASCONSIP_RATE;
    c += ASCONSIP_RATE;
    clen -= ASCONSIP_RATE;
  }
  /* final ciphertext block */
  if (clen >= 8) {
    uint64_t c0 = LOADBYTES(c, 8);
    uint64_t c1 = LOADBYTES(c + 8, (int)(clen - 8));
    STOREBYTES(m, s.x[0] ^ c0, 8);
    STOREBYTES(m + 8, s.x[1] ^ c1, (int)(clen - 8));
    s.x[0] = c0;
    s.x[1] = CLEARBYTES(s.x[1], (int)(clen - 8));
    s.x[1] |= c1;
    s.x[1] ^= PAD(clen - 8);
  } else {
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

  /* tag */
  STOREBYTES(t, s.x[2], 8);
  STOREBYTES(t + 8, s.x[3], 8);

  /* constant-time comparison */
  for (i = 0; i < ASCONSIP_TAGBYTES; ++i) result |= c[i] ^ t[i];
  result = (((result - 1) >> 8) & 1) - 1;

  return result;
}
