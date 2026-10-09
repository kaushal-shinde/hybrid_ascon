/*
 * Bitstream generator for the SipCon64 randomness tests.
 *
 *   ./gen_streams <mode> <rounds> <megabytes> <seed> <outfile>
 *
 * mode = ctstream | tag | permctr | permctr_rate
 *
 * Every byte written comes out of SipCon64 itself. The seeded PRNG in prng.h
 * is used only to draw the fixed key, never to produce output.
 *
 *
 * THE FOUR MODES, AND WHY EACH ONE EXISTS
 * ---------------------------------------
 * ctstream       One fixed random key, nonce = 128-bit counter, encrypt an
 *                all-zero message, write the ciphertext and discard the tag.
 *                This is the deployed AEAD at its real p^10/p^6 schedule, as a
 *                practitioner would use it. <rounds> is ignored.
 *
 *                Note this is the duplex's successive rate words, not a stream
 *                cipher's keystream: with P = 0 each block emits C_i = S_r and
 *                the duplex absorbs that same value back, so the state evolves
 *                under the permutation alone. C = P XOR keystream holds for the
 *                first rate block only, because the state absorbs C.
 *                selftest.c asserts both halves of that.
 *
 * tag            Same key, nonce = counter, empty message and AD, write the
 *                16-byte tag of each call. Tags come out of the finalisation
 *                permutation and the key XOR rather than out of the rate, so
 *                this exercises a different output path -- and it is the path
 *                a forger attacks. <rounds> is ignored.
 *
 * permctr        The bare permutation in counter mode: state = (ctr, 0, 0, 0),
 *                run p^<rounds>, write the whole 256-bit state. Here the round
 *                count is the variable, so sweeping <rounds> = 1..12 shows how
 *                many rounds the permutation needs before its output is
 *                statistically indistinguishable from random -- the number
 *                p^10/p^6 has to be judged against. The all-zero capacity and
 *                low-weight counter make this a deliberately hard input for
 *                the permutation, not an easy one.
 *
 * permctr_rate   As permctr, but writes only x0, the 64-bit rate word. In the
 *                real mode the capacity is never output, so this is the honest
 *                version of what an attacker observes per permutation call. It
 *                costs 4x more permutation calls per output byte.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "prng.h"
#include "sipcon64_harness.h"

#define CHUNK 65536

static void store64le(unsigned char* p, uint64_t v) {
  int i;
  for (i = 0; i < 8; ++i) p[i] = (unsigned char)(v >> (8 * i));
}

int main(int argc, char** argv) {
  const char *mode, *outpath;
  int rounds;
  double mb;
  uint64_t seed, total, written = 0, ctr = 0;
  unsigned char key[SIPCON64_KEYBYTES], npub[SIPCON64_NONCEBYTES];
  prng_t rng;
  FILE* out;

  if (argc != 6) {
    fprintf(stderr,
            "usage: %s ctstream|tag|permctr|permctr_rate <rounds> "
            "<megabytes> <seed> <outfile>\n",
            argv[0]);
    return 2;
  }
  mode = argv[1];
  rounds = atoi(argv[2]);
  mb = atof(argv[3]);
  seed = strtoull(argv[4], 0, 0);
  outpath = argv[5];

  total = (uint64_t)(mb * 1024.0 * 1024.0);
  prng_seed(&rng, seed);
  prng_bytes(&rng, key, sizeof key);
  memset(npub, 0, sizeof npub);

  out = fopen(outpath, "wb");
  if (!out) { perror(outpath); return 1; }

  if (strcmp(mode, "ctstream") == 0 || strcmp(mode, "tag") == 0) {
    const int is_tag = (strcmp(mode, "tag") == 0);
    const int mlen = is_tag ? 0 : 64;
    unsigned char m[64], c[64 + SIPCON64_TAGBYTES];
    unsigned long long cl;
    memset(m, 0, sizeof m);
    while (written < total) {
      store64le(npub, ctr);
      store64le(npub + 8, 0);
      sipcon64_aead_encrypt(c, &cl, m, (unsigned long long)mlen, 0, 0, 0, npub,
                            key);
      if (is_tag) {
        fwrite(c, 1, SIPCON64_TAGBYTES, out);
        written += SIPCON64_TAGBYTES;
      } else {
        fwrite(c, 1, (size_t)mlen, out);   /* ciphertext only, tag dropped */
        written += (uint64_t)mlen;
      }
      ctr++;
    }
  } else if (strcmp(mode, "permctr") == 0 ||
             strcmp(mode, "permctr_rate") == 0) {
    const int outw = (strcmp(mode, "permctr_rate") == 0) ? 1 : SEC_WORDS;
    unsigned char buf[CHUNK];
    size_t fill = 0;
    if (rounds < 1 || rounds > SEC_MAX_ROUNDS) {
      fprintf(stderr, "rounds must be 1..%d for %s\n", SEC_MAX_ROUNDS, mode);
      fclose(out);
      return 2;
    }
    while (written < total) {
      uint64_t st[SEC_WORDS];
      int w;
      memset(st, 0, sizeof st);
      st[0] = ctr++;
      sec_perm(st, rounds);
      for (w = 0; w < outw; ++w) {
        store64le(buf + fill, st[w]);
        fill += 8;
      }
      if (fill >= CHUNK - 64) {
        fwrite(buf, 1, fill, out);
        written += fill;
        fill = 0;
      }
    }
    if (fill) { fwrite(buf, 1, fill, out); written += fill; }
  } else {
    fprintf(stderr, "unknown mode: %s\n", mode);
    fclose(out);
    return 2;
  }

  fclose(out);
  fprintf(stderr, "SipCon64/%s r=%d: wrote %.2f MB to %s\n", mode, rounds,
          (double)written / (1024.0 * 1024.0), outpath);
  return 0;
}
