/* Redirects NIST's generator at the hybrid's own reference C, so the vectors
   it produces are computed by this construction rather than Ascon's. */
#ifndef CRYPTO_AEAD_H_
#define CRYPTO_AEAD_H_
#include "asconsip64.h"
#define crypto_aead_encrypt asconsip64_aead_encrypt
#define crypto_aead_decrypt asconsip64_aead_decrypt
#endif
