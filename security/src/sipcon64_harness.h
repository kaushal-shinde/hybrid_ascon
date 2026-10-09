/*
 * Shared definitions for the SipCon64 security harness.
 *
 * The permutation and the AEAD come straight from the project's own reference
 * implementation, ../../sipcon64/sipcon64.c, which is linked in. Nothing is
 * re-implemented here: the thing measured is the artefact the rest of the
 * project builds, simulates and ships, so a result here cannot drift away from
 * a second private copy of the cipher.
 *
 *
 * ROUND SCHEDULE
 * --------------
 * p^r takes its round constants from the *tail* of the 12-entry schedule,
 * RC[12-r .. 11], which is exactly what sipcon64_permutation() does and
 * therefore how the construction itself invokes p^10 and p^6.
 *
 * This means the round constants are part of the measurement. They do not
 * cancel out of a differential the way they would in a purely linear round:
 * SIPROUND's additions are modular and non-linear, so the output difference
 * depends on the actual state values and hence on the constants injected along
 * the way. Avalanche is therefore measured on p^r as the cipher invokes it,
 * not on a constant-stripped idealisation of it.
 */
#ifndef SEC_SIPCON64_HARNESS_H_
#define SEC_SIPCON64_HARNESS_H_

#include <stdint.h>
#include <string.h>

#include "../../sipcon64/sipcon64.h"

#define SEC_WORDS SIPCON64_STATEWORDS      /* 4 */
#define SEC_BITS (SEC_WORDS * 64)          /* 256 */
#define SEC_MAX_ROUNDS 12

/* Bit i of the state is bit (i % 64) of word (i / 64), LSB first. Word 0 is
 * x0, the rate: the only word data is absorbed into and squeezed out of. */
static inline void sec_flip_bit(uint64_t* st, int i) {
  st[i >> 6] ^= (uint64_t)1 << (i & 63);
}

static inline void sec_perm(uint64_t* st, int rounds) {
  sipcon64_permutation((sipcon64_state_t*)st, rounds);
}

#endif /* SEC_SIPCON64_HARNESS_H_ */
