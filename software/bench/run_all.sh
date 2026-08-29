#!/bin/bash
# Full pipeline: build all 12 .so's, benchmark them, compute static stack
# depth, extract ROM/RAM, merge into ../results.csv, then plot.
# Usage: ./run_all.sh   (from this directory, or anywhere -- paths are
# resolved relative to this script)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

./build.sh

gcc -O2 -o driver driver.c -ldl -lpthread
echo "label,keybytes,npubbytes,abytes,latency_cycles,cycles_per_byte,MBps,stack_bytes" > raw_results.csv
for label in ascon hybrid_r128 hybrid_r64 tinyjambu xoodyak giftcofb grain sparkle elephant isap photonbeetle romulus; do
  echo "benchmarking $label..." >&2
  ./driver "$label" "build/${label}.so" >> raw_results.csv
done

python3 stackcalc.py

for f in ascon hybrid_r128 hybrid_r64 tinyjambu xoodyak giftcofb grain sparkle elephant isap photonbeetle romulus; do
  size "build/$f.so" | tail -1 | awk -v n="$f" '{print n","$1","$2","$3}'
done > size_results.csv

python3 merge.py

cd "$HERE/.."
python3 make_graphs.py

echo "RUN_ALL_DONE"
