/* Redirects NIST's generator at the hybrid's own reference C, so the vectors
   it produces are computed by this construction rather than Ascon's. */
#ifndef CRYPTO_AEAD_H_
#define CRYPTO_AEAD_H_
#include "sipcon64.h"
#define crypto_aead_encrypt sipcon64_aead_encrypt
#define crypto_aead_decrypt sipcon64_aead_decrypt
#endif
