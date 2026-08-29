#!/bin/bash
# Compile all 12 official/reference C implementations into shared libraries
# with a uniform bench_* ABI (see wrap/wrapper.c), for native x86_64
# profiling: latency, throughput, stack high-water-mark, ROM/RAM proxy.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="/home/nesec/Desktop/projects/ascon hybrid"
OUT="$HERE/build"
mkdir -p "$OUT"
CC=gcc
CFLAGS="-O2 -fPIC -fstack-usage -Wno-implicit-function-declaration -Wno-unused-result"

build() {
  local label="$1"; shift
  local srcdir="$1"; shift
  local extra_defs="$1"; shift
  local files=("$@")

  local su_dir="$OUT/su_$label"
  mkdir -p "$su_dir"
  local objs=()
  for f in "${files[@]}"; do
    local obj="$su_dir/$(basename "${f%.c}").o"
    $CC $CFLAGS -I"$srcdir" -I"$FIN" $extra_defs -c "$srcdir/$f" -o "$obj"
    objs+=("$obj")
  done
  # wrapper.c compiled with the same include path + defs so it sees the
  # algorithm's own api.h (via -include) or the explicit -D fallback.
  local wobj="$su_dir/wrapper.o"
  $CC $CFLAGS -I"$srcdir" -I"$FIN" $extra_defs -c "$HERE/wrap/wrapper.c" -o "$wobj"
  objs+=("$wobj")

  $CC -shared -O2 -o "$OUT/${label}.so" "${objs[@]}"
  # move .su files (generated next to the .o by -fstack-usage) into su_dir
  mv "$srcdir"/*.su "$su_dir"/ 2>/dev/null || true
  mv "$HERE/wrap"/*.su "$su_dir"/ 2>/dev/null || true
  echo "built $label -> $(basename "$OUT/${label}.so")"
}

FIN="$ROOT/lwc-finalists"

build ascon "$ROOT/ascon-aead128" "-include api.h" aead.c
build hybrid_r128 "$ROOT/ascon-siphash" "-DKEYBYTES=16 -DNPUBBYTES=16 -DABYTES=16 -DENCRYPT_FN=asconsip_aead_encrypt" asconsip.c
build hybrid_r64 "$ROOT/ascon-siphash" "-DKEYBYTES=16 -DNPUBBYTES=16 -DABYTES=16 -DENCRYPT_FN=asconsip64_aead_encrypt" asconsip64.c
build tinyjambu "$FIN/tinyjambu" "-include api.h" encrypt.c
build xoodyak "$FIN/xoodyak" "-include api.h" encrypt.c Xoodyak.c Xoodoo-reference.c
build giftcofb "$FIN/gift-cofb" "-include api.h" encrypt.c gift128.c
build grain "$FIN/grain-128aead" "-include api.h" grain128aead-v2.c
build sparkle "$FIN/sparkle" "-include api.h" encrypt.c sparkle_ref.c
build elephant "$FIN/elephant" "-include api.h" encrypt.c spongent.c
build isap "$FIN/isap" "-include api.h" crypto_aead.c isap.c Ascon-reference.c
build photonbeetle "$FIN/photon-beetle" "-include api.h" encrypt.c photon.c
build romulus "$FIN/romulus" "-include api.h" encrypt.c decrypt.c romulus_n_reference.c skinny_reference.c

echo "BUILD_ALL_DONE"
