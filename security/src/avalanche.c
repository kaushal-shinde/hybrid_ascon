/*
 * Avalanche measurement for SipCon64.
 *
 *   ./avalanche perm <samples> <seed> <outdir>
 *   ./avalanche aead <samples> <seed> <outdir>
 *
 *
 * "perm" -- ROUND-WISE AVALANCHE OF THE PERMUTATION
 * -------------------------------------------------
 * For every round count r = 1..12, every one of the 256 input bit positions i,
 * and <samples> uniformly random states S:
 *
 *     D = p^r(S) XOR p^r(S XOR e_i)
 *
 * Three things are accumulated from D, in increasing order of sharpness:
 *
 *   avalanche    the Hamming weight of D -- how many output bits moved. The
 *                average over all (S, i) is the headline round-wise avalanche
 *                figure and should approach 128 of 256 bits, i.e. 50%.
 *
 *   SAC          the per-cell probability p_ij that output bit j flips when
 *                input bit i flips. The strict avalanche criterion asks
 *                p_ij = 1/2 for every one of the 256*256 cells, which is a far
 *                stronger demand than the average being 50%: an average of
 *                exactly 50% is equally consistent with half the output bits
 *                always flipping and half never flipping, and only the matrix
 *                tells those apart.
 *
 *   completeness how many (i, j) pairs show any dependence at all. This
 *                saturates before SAC does and marks the round at which every
 *                input bit has reached every output bit.
 *
 * The SAC accumulator is also written out aggregated into 64x64 word blocks.
 * That is the view a sponge needs: an attacker writes to and reads from the
 * rate word x0 alone, so how quickly influence crosses between x0 and the
 * capacity words x1..x3 is a sharper question than how quickly the state mixes
 * as a whole.
 *
 *
 * "aead" -- AVALANCHE OF THE FULL AEAD CALL
 * -----------------------------------------
 * The same experiment one level up, on a fixed 64-byte message with 16-byte
 * associated data: flip one bit of the key / nonce / associated data /
 * plaintext and measure how much of the ciphertext and tag changes. Reported
 * per input class and, separately, per individual input bit -- a single weak
 * key bit would disappear into a class average.
 *
 * The plaintext class needs care. In a duplex sponge, flipping a plaintext bit
 * in block j cannot change ciphertext blocks before j: C_i = S_r XOR P_i, and
 * the state at block i < j has not absorbed the flip yet. A whole-ciphertext
 * avalanche figure for a plaintext flip is therefore below 50% by construction
 * and says nothing about the quality of the cipher. The tag is the meaningful
 * target there, and it is reported separately for every class.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "prng.h"
#include "sipcon64_harness.h"

#ifdef _OPENMP
#include <omp.h>
#endif

/* Rounds whose full SAC matrix is dumped for the heatmap figures. */
static const int DUMP_ROUNDS[] = {1, 2, 3, 4, 5, 6, 8, 10, 12};
#define N_DUMP ((int)(sizeof(DUMP_ROUNDS) / sizeof(DUMP_ROUNDS[0])))

/* -------------------------------------------------------------- perm mode - */

static int run_perm(long samples, uint64_t seed, const char* outdir) {
  const size_t mat_cells = (size_t)SEC_BITS * SEC_BITS;
  int nthreads = 1;
  char path[1024];
  FILE* f;
  int r, i, t;

#ifdef _OPENMP
  nthreads = omp_get_max_threads();
#endif

  /* Per-thread accumulators, reduced at the end. */
  uint32_t* sac = calloc((size_t)nthreads * 13 * mat_cells, sizeof(uint32_t));
  uint64_t* hw_sum = calloc((size_t)nthreads * 13, sizeof(uint64_t));
  uint64_t* hw_sqsum = calloc((size_t)nthreads * 13, sizeof(uint64_t));
  uint32_t* hw_min = malloc((size_t)nthreads * 13 * sizeof(uint32_t));
  uint32_t* hw_max = calloc((size_t)nthreads * 13, sizeof(uint32_t));
  uint64_t* bit_sum =
      calloc((size_t)nthreads * 13 * SEC_BITS, sizeof(uint64_t));

  if (!sac || !hw_sum || !hw_sqsum || !hw_min || !hw_max || !bit_sum) {
    fprintf(stderr, "avalanche: out of memory\n");
    return 1;
  }
  for (i = 0; i < nthreads * 13; ++i) hw_min[i] = 0xffffffffu;

  fprintf(stderr,
          "SipCon64 permutation: %d-bit state, %ld samples x %d input bits "
          "x 12 rounds = %.2f M differential pairs, %d thread(s)\n",
          SEC_BITS, samples, SEC_BITS,
          (double)samples * SEC_BITS * 12 / 1e6, nthreads);

#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
  for (long s = 0; s < samples; ++s) {
    int tid = 0;
    uint64_t base[SEC_WORDS];
    uint64_t ref[13][SEC_WORDS];
    uint64_t cur[SEC_WORDS];
    prng_t rng;
    int rr, ii, w;
    uint32_t* my_sac;
    uint64_t *my_hw, *my_sq, *my_bit;
    uint32_t *my_min, *my_max;

#ifdef _OPENMP
    tid = omp_get_thread_num();
#endif
    my_sac = sac + (size_t)tid * 13 * mat_cells;
    my_hw = hw_sum + (size_t)tid * 13;
    my_sq = hw_sqsum + (size_t)tid * 13;
    my_min = hw_min + (size_t)tid * 13;
    my_max = hw_max + (size_t)tid * 13;
    my_bit = bit_sum + (size_t)tid * 13 * SEC_BITS;

    /* Seeded per sample rather than per thread, so every number this program
     * prints is identical whatever the thread count on the machine running
     * it. The self-test and run_all.sh both rely on that. */
    prng_seed(&rng, seed + 0x9E3779B97F4A7C15ULL * (uint64_t)s);
    for (w = 0; w < SEC_WORDS; ++w) base[w] = prng_next(&rng);

    for (rr = 1; rr <= 12; ++rr) {
      memcpy(ref[rr], base, sizeof base);
      sec_perm(ref[rr], rr);
    }

    for (ii = 0; ii < SEC_BITS; ++ii) {
      for (rr = 1; rr <= 12; ++rr) {
        uint32_t* row =
            my_sac + (size_t)rr * mat_cells + (size_t)ii * SEC_BITS;
        int hw = 0;
        memcpy(cur, base, sizeof base);
        sec_flip_bit(cur, ii);
        sec_perm(cur, rr);
        for (w = 0; w < SEC_WORDS; ++w) {
          uint64_t d = cur[w] ^ ref[rr][w];
          hw += __builtin_popcountll(d);
          while (d) {
            int j = __builtin_ctzll(d);
            row[w * 64 + j]++;
            d &= d - 1;
          }
        }
        my_hw[rr] += (uint64_t)hw;
        my_sq[rr] += (uint64_t)hw * (uint64_t)hw;
        if ((uint32_t)hw < my_min[rr]) my_min[rr] = (uint32_t)hw;
        if ((uint32_t)hw > my_max[rr]) my_max[rr] = (uint32_t)hw;
        my_bit[(size_t)rr * SEC_BITS + ii] += (uint64_t)hw;
      }
    }
  }

  for (t = 1; t < nthreads; ++t) {
    size_t k;
    for (k = 0; k < (size_t)13 * mat_cells; ++k)
      sac[k] += sac[(size_t)t * 13 * mat_cells + k];
    for (r = 0; r < 13; ++r) {
      hw_sum[r] += hw_sum[t * 13 + r];
      hw_sqsum[r] += hw_sqsum[t * 13 + r];
      if (hw_min[t * 13 + r] < hw_min[r]) hw_min[r] = hw_min[t * 13 + r];
      if (hw_max[t * 13 + r] > hw_max[r]) hw_max[r] = hw_max[t * 13 + r];
    }
    for (k = 0; k < (size_t)13 * SEC_BITS; ++k)
      bit_sum[k] += bit_sum[(size_t)t * 13 * SEC_BITS + k];
  }

  /* ---- the headline: round-wise avalanche average ---- */
  snprintf(path, sizeof path, "%s/avalanche_rounds.csv", outdir);
  f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f,
          "state_bits,round,samples,pairs,mean_flipped_bits,mean_pct,sd_pct,"
          "min_pct,max_pct\n");
  for (r = 1; r <= 12; ++r) {
    double n = (double)samples * SEC_BITS;
    double mean = (double)hw_sum[r] / n;
    double var = (double)hw_sqsum[r] / n - mean * mean;
    if (var < 0) var = 0;
    fprintf(f, "%d,%d,%ld,%.0f,%.4f,%.4f,%.4f,%.4f,%.4f\n", SEC_BITS, r,
            samples, n, mean, 100.0 * mean / SEC_BITS,
            100.0 * sqrt(var) / SEC_BITS, 100.0 * hw_min[r] / SEC_BITS,
            100.0 * hw_max[r] / SEC_BITS);
  }
  fclose(f);

  /* ---- SAC summary per round ---- */
  snprintf(path, sizeof path, "%s/sac_rounds.csv", outdir);
  f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f,
          "state_bits,round,samples_per_cell,cells,mean_abs_dev,max_abs_dev,"
          "chi2,dof,dependent_cells,completeness_pct,noise_sd,"
          "cells_beyond_6sd\n");
  for (r = 1; r <= 12; ++r) {
    const uint32_t* m = sac + (size_t)r * mat_cells;
    double sum_abs = 0.0, max_abs = 0.0, chi2 = 0.0;
    double sd = 0.5 / sqrt((double)samples);
    size_t k, dep = 0, beyond = 0;
    for (k = 0; k < mat_cells; ++k) {
      double p = (double)m[k] / (double)samples;
      double dv = p - 0.5;
      double ad = dv < 0 ? -dv : dv;
      sum_abs += ad;
      if (ad > max_abs) max_abs = ad;
      chi2 += 4.0 * dv * dv * (double)samples;
      if (m[k] != 0) dep++;
      if (ad > 6.0 * sd) beyond++;
    }
    fprintf(f, "%d,%d,%ld,%zu,%.6f,%.6f,%.3f,%zu,%zu,%.4f,%.6f,%zu\n",
            SEC_BITS, r, samples, mat_cells, sum_abs / mat_cells, max_abs,
            chi2, mat_cells, dep,
            100.0 * (double)dep / (double)mat_cells, sd, beyond);
  }
  fclose(f);

  /* ---- per-input-bit avalanche ---- */
  snprintf(path, sizeof path, "%s/avalanche_bitwise.csv", outdir);
  f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f, "round,input_bit,word,bit_in_word,role,mean_pct\n");
  for (r = 1; r <= 12; ++r)
    for (i = 0; i < SEC_BITS; ++i)
      fprintf(f, "%d,%d,%d,%d,%s,%.4f\n", r, i, i / 64, i % 64,
              i < 64 ? "rate" : "capacity",
              100.0 * (double)bit_sum[(size_t)r * SEC_BITS + i] /
                  ((double)samples * SEC_BITS));
  fclose(f);

  /* ---- word-level diffusion (rate vs capacity) ---- */
  snprintf(path, sizeof path, "%s/diffusion_words.csv", outdir);
  f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f, "round,in_word,out_word,in_role,out_role,mean_flip_pct,"
             "mean_abs_dev,dependent_cells,cells,completeness_pct\n");
  for (r = 1; r <= 12; ++r) {
    const uint32_t* m = sac + (size_t)r * mat_cells;
    int wi, wj;
    for (wi = 0; wi < SEC_WORDS; ++wi)
      for (wj = 0; wj < SEC_WORDS; ++wj) {
        double sum_p = 0.0, sum_abs = 0.0;
        size_t dep = 0, bi, bj;
        for (bi = 0; bi < 64; ++bi)
          for (bj = 0; bj < 64; ++bj) {
            size_t ii = (size_t)wi * 64 + bi, jj = (size_t)wj * 64 + bj;
            uint32_t c = m[ii * SEC_BITS + jj];
            double p = (double)c / (double)samples;
            sum_p += p;
            sum_abs += (p < 0.5 ? 0.5 - p : p - 0.5);
            if (c != 0) dep++;
          }
        fprintf(f, "%d,%d,%d,%s,%s,%.5f,%.6f,%zu,%d,%.4f\n", r, wi, wj,
                wi == 0 ? "rate" : "capacity",
                wj == 0 ? "rate" : "capacity", 100.0 * sum_p / 4096.0,
                sum_abs / 4096.0, dep, 4096, 100.0 * (double)dep / 4096.0);
      }
  }
  fclose(f);

  /* ---- raw SAC matrices for the heatmaps ---- */
  for (i = 0; i < N_DUMP; ++i) {
    r = DUMP_ROUNDS[i];
    snprintf(path, sizeof path, "%s/sacmat_r%d.u32", outdir, r);
    f = fopen(path, "wb");
    if (!f) { perror(path); return 1; }
    fwrite(sac + (size_t)r * mat_cells, sizeof(uint32_t), mat_cells, f);
    fclose(f);
  }

  free(sac); free(hw_sum); free(hw_sqsum); free(hw_min); free(hw_max);
  free(bit_sum);
  return 0;
}

/* -------------------------------------------------------------- aead mode - */

#define AEAD_MLEN 64
#define AEAD_ADLEN 16
#define AEAD_TLEN SIPCON64_TAGBYTES
#define AEAD_CLEN (AEAD_MLEN + AEAD_TLEN)

static int diff_bits(const unsigned char* a, const unsigned char* b, int n) {
  int i, c = 0;
  for (i = 0; i < n; ++i) c += __builtin_popcount((unsigned)(a[i] ^ b[i]));
  return c;
}

enum { CLS_KEY = 0, CLS_NPUB, CLS_AD, CLS_PT, N_CLS };
static const char* CLS_NAME[N_CLS] = {"key", "nonce", "ad", "plaintext"};

static int run_aead(long samples, uint64_t seed, const char* outdir) {
  const int cls_bits[N_CLS] = {SIPCON64_KEYBYTES * 8, SIPCON64_NONCEBYTES * 8,
                               AEAD_ADLEN * 8, AEAD_MLEN * 8};
  const int max_bits = AEAD_MLEN * 8;
  double* sum_ct = calloc((size_t)N_CLS * max_bits, sizeof(double));
  double* sum_tag = calloc((size_t)N_CLS * max_bits, sizeof(double));
  double* sum_c = calloc((size_t)N_CLS * max_bits, sizeof(double));
  double sq_ct[N_CLS] = {0}, sq_tag[N_CLS] = {0};
  double tot_ct[N_CLS] = {0}, tot_tag[N_CLS] = {0}, tot_c[N_CLS] = {0};
  int min_tag[N_CLS], max_tag[N_CLS];
  prng_t rng;
  char path[1024];
  FILE* f;
  int c, b;
  long s;

  if (!sum_ct || !sum_tag || !sum_c) {
    fprintf(stderr, "avalanche: out of memory\n");
    return 1;
  }
  for (c = 0; c < N_CLS; ++c) { min_tag[c] = 1 << 30; max_tag[c] = 0; }

  fprintf(stderr,
          "SipCon64 AEAD: %ld samples, %d-byte message, %d-byte AD, "
          "%d input bits per sample\n",
          samples, AEAD_MLEN, AEAD_ADLEN,
          cls_bits[0] + cls_bits[1] + cls_bits[2] + cls_bits[3]);

  prng_seed(&rng, seed);
  for (s = 0; s < samples; ++s) {
    unsigned char k[SIPCON64_KEYBYTES], npub[SIPCON64_NONCEBYTES];
    unsigned char ad[AEAD_ADLEN], m[AEAD_MLEN];
    unsigned char ref[AEAD_CLEN], out[AEAD_CLEN];
    unsigned long long cl;

    prng_bytes(&rng, k, sizeof k);
    prng_bytes(&rng, npub, sizeof npub);
    prng_bytes(&rng, ad, sizeof ad);
    prng_bytes(&rng, m, sizeof m);
    sipcon64_aead_encrypt(ref, &cl, m, AEAD_MLEN, ad, AEAD_ADLEN, 0, npub, k);

    for (c = 0; c < N_CLS; ++c) {
      unsigned char* tgt = (c == CLS_KEY)    ? k
                           : (c == CLS_NPUB) ? npub
                           : (c == CLS_AD)   ? ad
                                             : m;
      for (b = 0; b < cls_bits[c]; ++b) {
        int dct, dtag, dc;
        tgt[b >> 3] ^= (unsigned char)(1u << (b & 7));
        sipcon64_aead_encrypt(out, &cl, m, AEAD_MLEN, ad, AEAD_ADLEN, 0, npub,
                              k);
        tgt[b >> 3] ^= (unsigned char)(1u << (b & 7));

        dct = diff_bits(ref, out, AEAD_CLEN);
        dtag = diff_bits(ref + AEAD_MLEN, out + AEAD_MLEN, AEAD_TLEN);
        dc = dct - dtag;

        sum_ct[c * max_bits + b] += dct;
        sum_tag[c * max_bits + b] += dtag;
        sum_c[c * max_bits + b] += dc;
        tot_ct[c] += dct;
        tot_tag[c] += dtag;
        tot_c[c] += dc;
        sq_ct[c] += (double)dct * dct;
        sq_tag[c] += (double)dtag * dtag;
        if (dtag < min_tag[c]) min_tag[c] = dtag;
        if (dtag > max_tag[c]) max_tag[c] = dtag;
      }
    }
  }

  snprintf(path, sizeof path, "%s/avalanche_aead.csv", outdir);
  f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f,
          "input_class,input_bits,samples,trials,ct_mean_pct,ct_sd_pct,"
          "c_mean_pct,tag_mean_pct,tag_sd_pct,tag_min_pct,tag_max_pct\n");
  for (c = 0; c < N_CLS; ++c) {
    double n = (double)samples * cls_bits[c];
    double mct = tot_ct[c] / n, mtag = tot_tag[c] / n, mc = tot_c[c] / n;
    double vct = sq_ct[c] / n - mct * mct;
    double vtag = sq_tag[c] / n - mtag * mtag;
    if (vct < 0) vct = 0;
    if (vtag < 0) vtag = 0;
    fprintf(f, "%s,%d,%ld,%.0f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
            CLS_NAME[c], cls_bits[c], samples, n,
            100.0 * mct / (AEAD_CLEN * 8), 100.0 * sqrt(vct) / (AEAD_CLEN * 8),
            100.0 * mc / (AEAD_MLEN * 8), 100.0 * mtag / (AEAD_TLEN * 8),
            100.0 * sqrt(vtag) / (AEAD_TLEN * 8),
            100.0 * min_tag[c] / (AEAD_TLEN * 8),
            100.0 * max_tag[c] / (AEAD_TLEN * 8));
  }
  fclose(f);

  snprintf(path, sizeof path, "%s/avalanche_aead_bitwise.csv", outdir);
  f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f, "input_class,input_bit,ct_mean_pct,c_mean_pct,tag_mean_pct\n");
  for (c = 0; c < N_CLS; ++c)
    for (b = 0; b < cls_bits[c]; ++b)
      fprintf(f, "%s,%d,%.4f,%.4f,%.4f\n", CLS_NAME[c], b,
              100.0 * sum_ct[c * max_bits + b] /
                  ((double)samples * AEAD_CLEN * 8),
              100.0 * sum_c[c * max_bits + b] /
                  ((double)samples * AEAD_MLEN * 8),
              100.0 * sum_tag[c * max_bits + b] /
                  ((double)samples * AEAD_TLEN * 8));
  fclose(f);

  free(sum_ct); free(sum_tag); free(sum_c);
  return 0;
}

int main(int argc, char** argv) {
  long samples;
  uint64_t seed;

  if (argc != 5) {
    fprintf(stderr, "usage: %s perm|aead <samples> <seed> <outdir>\n",
            argv[0]);
    return 2;
  }
  samples = strtol(argv[2], 0, 10);
  seed = strtoull(argv[3], 0, 0);
  if (samples <= 0) { fprintf(stderr, "samples must be > 0\n"); return 2; }

  if (strcmp(argv[1], "perm") == 0) return run_perm(samples, seed, argv[4]);
  if (strcmp(argv[1], "aead") == 0) return run_aead(samples, seed, argv[4]);
  fprintf(stderr, "unknown mode: %s\n", argv[1]);
  return 2;
}
