#!/bin/bash
# Run the Vivado OOC period search over all eleven designs.
#
# Resumable: a design whose *_result.csv already exists is skipped, so an
# interrupted sweep can be restarted without losing completed work.
#
# Each Vivado process is single-threaded and deterministic, so running several
# designs concurrently changes wall time only, never the numbers.
#
# Usage: ./run_vivado.sh [iters] [jobs]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
ITERS="${1:-7}"
JOBS="${2:-4}"

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/home/2026.1/Vivado/settings64.sh}"
[ -f "$VIVADO_SETTINGS" ] && source "$VIVADO_SETTINGS" >/dev/null 2>&1
command -v vivado >/dev/null || { echo "vivado not on PATH (set VIVADO_SETTINGS)"; exit 1; }

# Vivado breaks on paths containing spaces and the repository path has one, so
# all build artifacts go to a space-free directory outside the repo. Durable
# (not /tmp) so a long sweep survives across sessions; override with FLOW_WORK.
WORK="${FLOW_WORK:-$HOME/.ascon-flow/vivado}"
case "$WORK" in *[[:space:]]*) echo "FLOW_WORK must not contain spaces: $WORK"; exit 1;; esac
mkdir -p "$WORK/rtl" "$WORK/out" "$WORK/logs"
cp "$ROOT/verilog/"*.v "$WORK/rtl/"

DESIGNS="ascon_aead128 asconsip64_aead tinyjambu_lwc xoodyak_lwc giftcofb_lwc
         grain128aead_lwc sparkle_lwc elephant_lwc isap_lwc photonbeetle_lwc
         romulus_n_lwc"

run_one() {
  d="$1"
  od="$WORK/out/$d"
  if [ -f "$od/${d}_result.csv" ]; then
    echo "SKIP $d (already done)"; return 0
  fi
  rm -rf "$od"; mkdir -p "$od"
  ( cd "$od" && DESIGN="$d" RTL="$WORK/rtl/$d.v" OUTDIR="$od" ITERS="$ITERS" \
      timeout 10800 vivado -mode batch -nojournal -nolog \
        -source "$HERE/vivado_flow.tcl" ) > "$WORK/logs/$d.log" 2>&1
  if [ -f "$od/${d}_result.csv" ]; then
    echo "DONE $d: $(tail -1 "$od/${d}_result.csv")"
  else
    echo "FAIL $d -- see $WORK/logs/$d.log"
  fi
}
export -f run_one; export WORK HERE ITERS

echo "=== Vivado sweep: $ITERS iterations, $JOBS concurrent ==="
printf '%s\n' $DESIGNS | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}

OUT="$HERE/vivado_results.csv"
echo "design,period_ns,fmax_mhz,luts,regs,unrouted,dyn_power_mw" > "$OUT"
for d in $DESIGNS; do
  [ -f "$WORK/out/$d/${d}_result.csv" ] && tail -1 "$WORK/out/$d/${d}_result.csv" >> "$OUT"
done
echo "=== VIVADO SWEEP COMPLETE -> $OUT ==="
cat "$OUT"
