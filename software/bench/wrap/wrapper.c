/* Generic benchmark wrapper: exposes a fixed symbol set (bench_*) so the
 * driver can dlopen() every algorithm's .so without symbol collisions
 * (every reference implementation exports crypto_aead_encrypt under the
 * exact same name). ENCRYPT_FN/KEYBYTES/NPUBBYTES/ABYTES are supplied via
 * -D on the compile line per algorithm. */
#include <string.h>

#ifndef KEYBYTES
#define KEYBYTES CRYPTO_KEYBYTES
#endif
#ifndef NPUBBYTES
#define NPUBBYTES CRYPTO_NPUBBYTES
#endif
#ifndef ABYTES
#define ABYTES CRYPTO_ABYTES
#endif
#ifndef ENCRYPT_FN
#define ENCRYPT_FN crypto_aead_encrypt
#endif

extern int ENCRYPT_FN(unsigned char *c, unsigned long long *clen,
    const unsigned char *m, unsigned long long mlen,
    const unsigned char *ad, unsigned long long adlen,
    const unsigned char *nsec, const unsigned char *npub,
    const unsigned char *k);

int bench_key_bytes(void)  { return KEYBYTES; }
int bench_npub_bytes(void) { return NPUBBYTES; }
int bench_abytes(void)     { return ABYTES; }

int bench_encrypt(unsigned char *c, unsigned long long *clen,
                   const unsigned char *m, unsigned long long mlen,
                   const unsigned char *ad, unsigned long long adlen,
                   const unsigned char *npub, const unsigned char *k) {
  return ENCRYPT_FN(c, clen, m, mlen, ad, adlen, (void*)0, npub, k);
}
