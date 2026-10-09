# Security analysis: SipCon64

Statistical security analysis of the SipCon64 hybrid, on its own terms:

1. **Round-wise avalanche effect** — the average fraction of output bits that
   change when one input bit is flipped, measured at every round count from 1
   to 12, plus the strict avalanche criterion and word-level diffusion behind
   that average.
2. **Randomness tests** — the full NIST SP 800-22 Rev. 1a suite, all fifteen
   tests, on the deployed AEAD and on the bare permutation swept across round
   counts.

Every measure is scored against an **absolute** reference — 50% avalanche,
`p_ij` = 1/2, alpha = 0.01, or what sampling noise alone produces at this
sample size. No other cipher appears in any result, and none is needed to read
one.

Results and discussion: [`SECURITY-RESULTS.md`](SECURITY-RESULTS.md).

**Read this first.** Nothing in this directory is cryptanalysis, and nothing in
it is evidence that SipCon64 is secure. Avalanche and SP 800-22 are *necessary*
conditions that every serious cipher satisfies, including broken ones: a
reduced-round cipher can show perfect 50% avalanche and pass all fifteen tests
while still falling to differential, linear, cube or algebraic attacks, none of
which these tests look for. What this directory establishes is the absence of
gross statistical defects and the round count at which diffusion saturates. The
claim in [`../sipcon64/README.md`](../sipcon64/README.md) — that the
construction has had **no dedicated cryptanalysis** — is unchanged by
everything here.

## Layout

```
src/
  sipcon64_harness.h   thin adapter onto ../../sipcon64/ (nothing re-implemented)
  prng.h               seeded xoshiro256** -- draws test inputs, never test output
  avalanche.c          round-wise avalanche, SAC, word diffusion, AEAD avalanche
  gen_streams.c        SipCon64 bitstreams for the randomness tests, four modes
  selftest.c           pins the reference and proves the harness is wired right
sts/
  nist_sts.py          all 15 SP 800-22 Rev 1a tests, implemented here
  validate_sts.py      proves the suite accepts a CSPRNG and rejects weak streams
results/               CSVs, raw SAC matrices, and both validation transcripts
graphs/                figures for the paper
run_all.sh             reproduces everything, in dependency order
make_graphs.py         figures from the CSVs
validate_palette.py    chart-palette colourblind/contrast check
```

`streams/` and `build/` are generated and not version-controlled; every stream
is reproducible from the seed in `run_all.sh`.

## Reproducing

```sh
./run_all.sh          # full run, ~12 min on 8 cores
./run_all.sh quick    # reduced samples, ~2 min, for a smoke test
```

Two gates run first and the pipeline aborts if either fails.

**1. `build/selftest`** checks the harness and the reference it links against,
not the cipher's security. It pins `p^12` of the zero state and a full AEAD
encryption to **frozen vectors generated from
[`../sipcon64/sipcon64.c`](../sipcon64/sipcon64.c) on 2026-10-01**, so if that
file is ever edited the run fails loudly instead of quietly describing a
different function. It also checks that the construction is still p^10/p^6 with
a 256-bit state and 64-bit rate, that reduced-round `p^r` really uses the tail
of the constant schedule rather than a shared prefix, that the bit indexing is
what the code says, that the AEAD round-trips and rejects tampering, that the
duplex behaves as `gen_streams` documents, and that the harness PRNG is not
degenerate. Fifteen checks in all.

**2. `sts/validate_sts.py`** checks the statistical suite the same way, by
running it on streams whose verdict is known in advance: `os.urandom` must
pass, and all-zero bytes, a 64-bit counter, an LCG's low byte and the **1-round
SipCon64 permutation** must all fail. The last is the domain-specific control —
it proves the suite can detect an under-mixed SipCon64, which is what the round
sweep depends on. It also confirms the p-values are uniform on random input,
the assumption the two-level NIST assessment rests on.

## Method

### Where the primitive comes from

`src/sipcon64_harness.h` calls `sipcon64_permutation()` and
`sipcon64_aead_encrypt()` from
[`../sipcon64/sipcon64.c`](../sipcon64/sipcon64.c) directly; the file is linked
in rather than copied. The same C is what `../SOFTWARE-RESULTS.md` profiles and
what the Verilog in `../verilog/` was transliterated from, so a result here
applies to the artefact the rest of the project measures and cannot drift away
from a second private copy.

Reduced-round `p^r` uses the **tail** of the 12-entry constant schedule,
`RC[12-r .. 11]`, because that is how the construction invokes `p^10` and `p^6`.
This means the round constants are part of the measurement: they do *not*
cancel out of a differential, because SIPROUND's additions are modular and
non-linear, so the output difference depends on the actual state values and
hence on the constants injected along the way.

### 1. Avalanche

For each round count r = 1..12, each of the 256 input bit positions i, and N
random states S, the harness computes `D = p^r(S) XOR p^r(S XOR e_i)` and
accumulates four things, in increasing order of sharpness:

- **avalanche** — the Hamming weight of D. Its average over all (S, i) is the
  round-wise avalanche figure, and should approach 128 of 256 bits.
- **SAC** — the per-cell probability `p_ij` that output bit j flips when input
  bit i flips. The strict avalanche criterion wants `p_ij = 1/2` for all 65 536
  cells, which is far stronger than the average being 50%: an average of
  exactly 50% is equally consistent with half the output bits always flipping
  and half never flipping, and only the matrix tells those apart.
- **completeness** — how many (i, j) pairs show any dependence at all. This
  saturates before SAC does and marks full diffusion.
- **word-level diffusion** — the same accumulator aggregated into 64×64 blocks,
  one figure per (input word, output word) pair. This is the view a sponge
  needs: an attacker writes to and reads from the rate word `x0` alone, so how
  fast influence crosses between `x0` and the capacity `x1`–`x3` is a sharper
  question than how fast the state mixes overall.

At N = 32 768 the per-cell sampling noise is `0.5/sqrt(N)` = 0.00276. Two
reference points follow and **both** are reported, because they differ by a
factor of ~4.7: the expected *mean* |deviation| from noise alone is
`sd*sqrt(2/pi)` = 0.0022, and the expected *maximum* over 65 536 cells is
`sd*sqrt(2*ln N)` = 0.0130. Using the per-cell sd as the yardstick for the worst
cell would make a fully converged permutation look biased.

AEAD-level avalanche repeats the experiment on the full encryption call,
flipping each bit of the key, nonce, associated data and plaintext in turn, and
reports the whole output and the tag alone, per class *and per individual input
bit* — a single weak key bit would vanish into a class average.

One structural point about the plaintext class: in any duplex sponge, flipping
a plaintext bit in block j cannot change ciphertext blocks before j, because
`C_i = S_r XOR P_i` and the state at block i < j has not absorbed the flip yet.
Whole-ciphertext avalanche for a plaintext flip is therefore below 50% by
construction and says nothing about cipher quality; the tag is the meaningful
target, and both are reported.

### 2. Randomness

`gen_streams.c` produces four kinds of bitstream, all from SipCon64 itself:

| mode | what it is | why |
|---|---|---|
| `ctstream` | ciphertext of an all-zero message, nonce = counter | the deployed AEAD as a practitioner uses it |
| `tag` | the tag of each counter-nonce call | a different output path — the bits a forger attacks |
| `permctr` | bare permutation on a counter, whole state out | makes the round count the variable |
| `permctr_rate` | as above but only `x0`, the rate word | what an attacker actually observes per call |

`permctr` is the one that matters for margin: sweeping r = 1..12 shows how many
rounds the permutation needs before its output is statistically
indistinguishable from random, which is the number p^10/p^6 has to be judged
against. Its all-zero capacity and low-weight counter make it a deliberately
hard input, not an easy one.

### Reading the verdict

Each stream is assessed as NIST specifies: 15 tests, several of which expand
into sub-tests (148 non-overlapping templates, 18 random-excursion-variant
states, 8 random-excursion states, 2 serial, 2 cumulative-sums), giving ~190
sub-tests. Each is run over many independent 1 000 000-bit sequences at
alpha = 0.01 and passes on two criteria — the proportion of sequences passing
must sit inside NIST's band, and the p-values must be uniform.

**With ~190 sub-tests at alpha = 0.01, a perfect generator is expected to fail
a few of them.** Reporting "3 sub-tests failed" without saying how many were
expected is therefore meaningless, so `suite_verdict()` computes each
sub-test's exact false-rejection probability — the proportion band is a 3-sigma
normal approximation applied to a discrete binomial count, so its true rate is
neither 0.0027 nor constant across sub-tests — sums them into an expected
failure count, and reports the Poisson tail probability of the observed count.
The sub-tests share sequences and so are not independent, which makes that tail
an approximation; it is used only to separate "a handful, as expected" from
"this stream is structured", which is a wide enough gap to carry.

## Sample sizes

| measurement | configuration |
|---|---|
| avalanche / SAC / word diffusion | 32 768 random states × 256 input bits × 12 rounds = 100.7 M pairs |
| AEAD avalanche | 2 048 random (key, nonce, AD, message) draws = 1.8 M encryptions |
| randomness, deployed streams | 128 sequences × 1 000 000 bits, 5 streams |
| randomness, round sweep | 32 sequences × 1 000 000 bits, r = 1..12 |

The sweep is deliberately smaller: its job is to locate the round at which the
permutation starts passing, not to certify a stream, and the threshold is sharp
enough that 32 sequences resolve it.

Results are deterministic and independent of thread count — the harness seeds
per sample rather than per thread, so a rerun on a different machine with the
same seed produces identical numbers.
