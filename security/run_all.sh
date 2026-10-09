#!/usr/bin/env bash
#
# Reproduce every number in SECURITY-RESULTS.md, from a clean checkout.
#
#   ./run_all.sh              full run, about 12 minutes on 8 cores
#   ./run_all.sh quick        reduced sample counts, for a smoke test
#
# Stages, in order, each gated on the one before:
#   0  build the C harnesses
#   1  harness self-tests            -- stop if the harness is miswired
#   2  validate the SP 800-22 suite  -- stop if the suite is miswired
#   3  round-wise avalanche, SAC and word-level diffusion
#   4  AEAD-level avalanche
#   5  generate SipCon64 bitstreams
#   6  randomness tests
#   7  charts
#
# Stages 1 and 2 exist because everything after them is only as good as the
# harness producing it. Stage 1 pins the reference implementation to frozen
# vectors, so an edit to ../sipcon64/sipcon64.c invalidates the run instead of
# silently changing what was measured. Stage 2 proves the statistical suite
# accepts a CSPRNG and rejects streams known to be weak, including a 1-round
# SipCon64.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-full}"
if [ "$MODE" = "quick" ]; then
  AV_SAMPLES=512;   AEAD_SAMPLES=128
  STS_SEQS=16;      SWEEP_SEQS=8
else
  AV_SAMPLES=32768; AEAD_SAMPLES=2048
  STS_SEQS=128;     SWEEP_SEQS=32
fi
STS_BITS=1000000
SEED=20260929

RESULTS=results
STREAMS=streams
mkdir -p build "$RESULTS" "$STREAMS" graphs

CC_OPTS="-O3 -march=native -Wall -Wextra"
REF=../sipcon64/sipcon64.c

echo "=== 0. build ==================================================="
gcc $CC_OPTS -fopenmp -o build/avalanche    src/avalanche.c    $REF -lm
gcc $CC_OPTS          -o build/gen_streams  src/gen_streams.c  $REF
gcc -O2 -Wall -Wextra -o build/selftest     src/selftest.c     $REF
echo "built."

echo
echo "=== 1. harness self-tests ======================================"
./build/selftest | tee "$RESULTS/selftest.txt"

echo
echo "=== 2. validate the SP 800-22 implementation ==================="
python3 sts/validate_sts.py --seqs "$SWEEP_SEQS" --bits "$STS_BITS" \
        --gen build/gen_streams | tee "$RESULTS/sts_validation.txt"

echo
echo "=== 3. round-wise avalanche, SAC, word diffusion ==============="
./build/avalanche perm "$AV_SAMPLES" "$SEED" "$RESULTS"

echo
echo "=== 4. AEAD-level avalanche ===================================="
./build/avalanche aead "$AEAD_SAMPLES" "$SEED" "$RESULTS"

echo
echo "=== 5. generate bitstreams ====================================="
hdr_mb=$(python3 -c "print($STS_SEQS * $STS_BITS / 8 / 1048576)")
swp_mb=$(python3 -c "print($SWEEP_SEQS * $STS_BITS / 8 / 1048576)")

# the deployed construction, at full sample size
./build/gen_streams ctstream     0  "$hdr_mb" "$SEED" "$STREAMS/ctstream.bin"
./build/gen_streams tag          0  "$hdr_mb" "$SEED" "$STREAMS/tag.bin"
# the permutation at the round counts the construction uses
./build/gen_streams permctr      10 "$hdr_mb" "$SEED" "$STREAMS/perm_r10.bin"
./build/gen_streams permctr      6  "$hdr_mb" "$SEED" "$STREAMS/perm_r6.bin"
./build/gen_streams permctr_rate 6  "$hdr_mb" "$SEED" "$STREAMS/permrate_r6.bin"
# round sweep, smaller sample size -- its job is to locate the threshold
for r in $(seq 1 12); do
  ./build/gen_streams permctr "$r" "$swp_mb" "$SEED" "$STREAMS/sweep_r$r.bin"
done

echo
echo "=== 6. randomness tests ========================================"
rm -f "$RESULTS"/sts_detail.csv "$RESULTS"/sts_summary.csv \
      "$RESULTS"/sts_sweep_detail.csv "$RESULTS"/sts_sweep_summary.csv

sts() {  # <file> <label> <seqs> <detail> <summary>
  python3 sts/nist_sts.py "$1" --seqs "$3" --bits "$STS_BITS" \
          --label "$2" --detail "$4" --summary "$5" || true
}

for s in ctstream tag perm_r10 perm_r6 permrate_r6; do
  sts "$STREAMS/$s.bin" "$s" "$STS_SEQS" \
      "$RESULTS/sts_detail.csv" "$RESULTS/sts_summary.csv"
done

for r in $(seq 1 12); do
  sts "$STREAMS/sweep_r$r.bin" "r$r" "$SWEEP_SEQS" \
      "$RESULTS/sts_sweep_detail.csv" "$RESULTS/sts_sweep_summary.csv"
done

echo
echo "=== 7. charts =================================================="
python3 make_graphs.py

echo
echo "done. results/ has the CSVs, graphs/ the figures."
echo "streams/ holds $(du -sh "$STREAMS" | cut -f1) of generated bitstreams;"
echo "they are reproducible from seed $SEED and are not version-controlled."
