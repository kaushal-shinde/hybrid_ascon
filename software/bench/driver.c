/* Benchmark driver: dlopen()s each algorithm's .so (built by build.sh,
 * uniform bench_* ABI from wrap/wrapper.c) and measures:
 *   - latency:     cycles for one encrypt() on a fixed 16B AD / 16B message
 *   - throughput:  cycles/byte and MB/s on a 4096-byte message
 *   - stack:       high-water-mark bytes used by encrypt(), via the
 *                  "stack painting" technique on an isolated pthread stack
 * Prints one CSV line per algorithm to stdout.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>

typedef int (*encrypt_fn)(unsigned char *, unsigned long long *,
                           const unsigned char *, unsigned long long,
                           const unsigned char *, unsigned long long,
                           const unsigned char *, const unsigned char *);
typedef int (*intfn)(void);

static inline uint64_t rdtsc(void) {
  unsigned int lo, hi;
  __asm__ __volatile__("cpuid\n\t" ::: "%rax","%rbx","%rcx","%rdx");
  __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
}

#define STACK_SZ (1 << 20) /* 1 MiB */
#define PAINT 0xAA

static encrypt_fn g_enc;
static const unsigned char *g_key, *g_npub, *g_ad, *g_m;
static unsigned long long g_adlen, g_mlen;
static unsigned char *g_c;
static unsigned long long g_clen;

static void *paint_and_call(void *arg) {
  unsigned char *base = (unsigned char *)arg; /* low end of the stack region */
  g_enc(g_c, &g_clen, g_m, g_mlen, g_ad, g_adlen, g_npub, g_key);
  /* high-water mark: lowest painted address that's still untouched, walking
   * up from base. Everything below that point was touched by the call (or
   * by the pthread entry trampoline itself, a small fixed cost common to
   * every run since they all launch through this exact same stub). */
  size_t i = 0;
  while (i < STACK_SZ && base[i] == PAINT) i++;
  return (void *)(uintptr_t)(STACK_SZ - i);
}

static size_t measure_stack(encrypt_fn enc,
    const unsigned char *key, const unsigned char *npub,
    const unsigned char *ad, unsigned long long adlen,
    const unsigned char *m, unsigned long long mlen,
    unsigned char *c, unsigned long long *clen) {
  g_enc = enc; g_key = key; g_npub = npub; g_ad = ad; g_adlen = adlen;
  g_m = m; g_mlen = mlen; g_c = c; g_clen = *clen;

  void *stackmem;
  if (posix_memalign(&stackmem, 4096, STACK_SZ) != 0) return 0;
  /* Paint from the MAIN thread, before the worker thread ever runs on this
   * memory -- painting from inside the worker itself would overwrite its
   * own already-live return address and crash (found the hard way). */
  memset(stackmem, PAINT, STACK_SZ);

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstack(&attr, stackmem, STACK_SZ);

  pthread_t th;
  void *ret = NULL;
  pthread_create(&th, &attr, paint_and_call, stackmem);
  pthread_join(th, &ret);
  pthread_attr_destroy(&attr);
  size_t used = (size_t)(uintptr_t)ret;
  free(stackmem);
  *clen = g_clen;
  return used;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s label lib.so\n", argv[0]); return 1; }
  const char *label = argv[1];
  const char *path = argv[2];

  void *h = dlopen(path, RTLD_NOW);
  if (!h) { fprintf(stderr, "%s: dlopen failed: %s\n", label, dlerror()); return 1; }

  encrypt_fn enc = (encrypt_fn)dlsym(h, "bench_encrypt");
  intfn keyb = (intfn)dlsym(h, "bench_key_bytes");
  intfn npubb = (intfn)dlsym(h, "bench_npub_bytes");
  intfn ab = (intfn)dlsym(h, "bench_abytes");
  if (!enc || !keyb || !npubb || !ab) {
    fprintf(stderr, "%s: missing symbols\n", label); return 1;
  }

  int kb = keyb(), nb = npubb(), abytes = ab();
  unsigned char key[64] = {0}, npub[64] = {0};
  for (int i = 0; i < kb; i++) key[i] = (unsigned char)(i * 7 + 1);
  for (int i = 0; i < nb; i++) npub[i] = (unsigned char)(i * 3 + 2);

  /* ---- latency: fixed small 16B AD / 16B message, many reps, median-ish */
  unsigned char ad16[16], m16[16], c16[16 + 64];
  for (int i = 0; i < 16; i++) { ad16[i] = i; m16[i] = 255 - i; }
  unsigned long long clen;

  /* warmup */
  for (int i = 0; i < 200; i++) {
    clen = sizeof(c16);
    enc(c16, &clen, m16, 16, ad16, 16, npub, key);
  }
  const int LAT_REPS = 20000;
  uint64_t best = UINT64_MAX;
  for (int i = 0; i < LAT_REPS; i++) {
    clen = sizeof(c16);
    uint64_t t0 = rdtsc();
    enc(c16, &clen, m16, 16, ad16, 16, npub, key);
    uint64_t t1 = rdtsc();
    uint64_t d = t1 - t0;
    if (d < best) best = d;
  }
  double latency_cycles = (double)best;

  /* ---- throughput: 4096B message, 0B AD, timed with clock_gettime over
   * many reps to smooth out rdtsc granularity at this size */
  const int MSZ = 4096;
  unsigned char *mbuf = malloc(MSZ), *cbuf = malloc(MSZ + 64);
  for (int i = 0; i < MSZ; i++) mbuf[i] = (unsigned char)i;
  const int TP_REPS = 2000;
  for (int i = 0; i < 50; i++) { clen = MSZ + 64; enc(cbuf, &clen, mbuf, MSZ, NULL, 0, npub, key); }
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (int i = 0; i < TP_REPS; i++) {
    clen = MSZ + 64;
    enc(cbuf, &clen, mbuf, MSZ, NULL, 0, npub, key);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
  double mb_per_s = ((double)MSZ * TP_REPS) / secs / (1024.0 * 1024.0);

  /* cycles/byte from the same 4096B buffer, rdtsc-timed, best-of-N */
  double cycles_per_byte;
  uint64_t bestN = UINT64_MAX;
  for (int i = 0; i < 300; i++) {
    clen = MSZ + 64;
    uint64_t s0 = rdtsc();
    enc(cbuf, &clen, mbuf, MSZ, NULL, 0, npub, key);
    uint64_t s1 = rdtsc();
    uint64_t d = s1 - s0;
    if (d < bestN) bestN = d;
  }
  cycles_per_byte = (double)bestN / MSZ;

  /* ---- stack high-water mark on the 16B/16B case */
  clen = sizeof(c16);
  size_t stack_used = measure_stack(enc, key, npub, ad16, 16, m16, 16, c16, &clen);

  printf("%s,%d,%d,%d,%.1f,%.4f,%.2f,%zu\n",
         label, kb, nb, abytes, latency_cycles, cycles_per_byte, mb_per_s, stack_used);

  free(mbuf); free(cbuf);
  dlclose(h);
  return 0;
}
