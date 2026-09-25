#!/bin/bash
# Full pipeline: build all 11 .so's, benchmark them (encrypt + decrypt,
# fixed-size latency/throughput + a multi-size throughput curve), compute
# static stack depth, extract ROM/RAM (+ .text/.rodata split), merge into
# ../results.csv, then plot.
# Usage: ./run_all.sh   (from this directory, or anywhere -- paths are
# resolved relative to this script)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

./build.sh

gcc -O2 -o driver driver.c -ldl -lpthread
echo "label,keybytes,npubbytes,abytes,latency_cycles,cycles_per_byte,MBps,stack_bytes,dec_latency_cycles,dec_cycles_per_byte,dec_MBps,dec_ok" > raw_results.csv
echo "label,size_bytes,cycles_per_byte" > curve_results.csv
for label in ascon sipcon64 tinyjambu xoodyak giftcofb grain sparkle elephant isap photonbeetle romulus; do
  echo "benchmarking $label..." >&2
  ./driver "$label" "build/${label}.so" curve_results.csv >> raw_results.csv
done

python3 stackcalc.py

for f in ascon sipcon64 tinyjambu xoodyak giftcofb grain sparkle elephant isap photonbeetle romulus; do
  size "build/$f.so" | tail -1 | awk -v n="$f" '{print n","$1","$2","$3}'
done > size_results.csv

# .text vs .rodata split (size's default "text" column above lumps .text,
# .rodata and a few smaller read-only/unwind sections together -- this
# breaks out the two that matter: code vs. lookup tables)
for f in ascon sipcon64 tinyjambu xoodyak giftcofb grain sparkle elephant isap photonbeetle romulus; do
  txt=$(size -A "build/$f.so" | awk '$1==".text"{print $2; found=1} END{if(!found) print 0}')
  rod=$(size -A "build/$f.so" | awk '$1==".rodata"{print $2; found=1} END{if(!found) print 0}')
  echo "$f,$txt,$rod"
done > section_results.csv

python3 merge.py

cd "$HERE/.."
python3 make_graphs.py

echo "RUN_ALL_DONE"
