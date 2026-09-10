#!/bin/bash
# yosys + OpenROAD on sky130hd for all eleven designs, with a period search
# matching the Vivado sweep's, so both tables come from one procedure.
#
# Resumable: designs with an existing result line are skipped.
#
# Usage: ./run_sky130.sh [iters] [jobs]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
ITERS="${1:-6}"
JOBS="${2:-4}"

PDK="${PDK:-$HOME/pdks/sky130hd}"
export TLEF="$PDK/lef/sky130_fd_sc_hd.tlef"
export SCLEF="$PDK/lef/sky130_fd_sc_hd_merged.lef"
export LIB="$PDK/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
export UTIL="${UTIL:-45}"
export DENSITY="${DENSITY:-0.60}"
for f in "$TLEF" "$SCLEF" "$LIB"; do
  [ -f "$f" ] || { echo "missing PDK file: $f"; exit 1; }
done

# Cells ORFS refuses to map to (power-gating, probe, level-shifter), taken from
# the platform's own config.mk so this tracks the PDK rather than a copy here.
DONTUSE="$(sed -n '/^export DONT_USE_CELLS/,/^[^ \t]/p' "$PDK/config.mk" \
           | grep -oE 'sky130_fd_sc_hd__[a-z0-9_]+' | sort -u \
           | sed 's/^/-dont_use /' | tr '\n' ' ')"
export DONTUSE
echo "excluding $(wc -w <<<"$DONTUSE" | awk '{print $1/2}') DONT_USE cells"

source "$HOME/miniconda3/etc/profile.d/conda.sh" 2>/dev/null && conda activate or-flow 2>/dev/null
command -v yosys   >/dev/null || { echo "yosys not on PATH";   exit 1; }
command -v openroad>/dev/null || { echo "openroad not on PATH";exit 1; }

WORK="${FLOW_WORK:-$HOME/.ascon-flow/sky130}"
case "$WORK" in *[[:space:]]*) echo "FLOW_WORK must not contain spaces"; exit 1;; esac
mkdir -p "$WORK/rtl" "$WORK/out" "$WORK/logs"
cp "$ROOT/verilog/"*.v "$WORK/rtl/"
# openroad splits its script argument on spaces and the repo path has one, so
# stage the scripts alongside the build artifacts.
cp "$HERE/sky130_pnr.tcl" "$HERE/sky130_syn.ys.in" "$WORK/"
PNR="$WORK/sky130_pnr.tcl"
SYNIN="$WORK/sky130_syn.ys.in"

DESIGNS="ascon_aead128 asconsip64_aead tinyjambu_lwc xoodyak_lwc giftcofb_lwc
         grain128aead_lwc sparkle_lwc elephant_lwc isap_lwc photonbeetle_lwc
         romulus_n_lwc"

# one synth+pnr attempt at a given clock period (ns); echoes "wns area insts"
attempt() {
  local d="$1" period="$2" od="$3"
  local ps; ps=$(awk -v p="$period" 'BEGIN{printf "%d", p*1000}')
  sed -e "s|@RTL@|$WORK/rtl/$d.v|" -e "s|@TOP@|$d|" -e "s|@LIB@|$LIB|" \
      -e "s|@DELAY_PS@|$ps|"       -e "s|@NETLIST@|$od/${d}_net.v|" \
      -e "s|@STATS@|$od/stat.txt|" -e "s|@DONTUSE@|$DONTUSE|" \
      "$SYNIN" > "$od/syn.ys"
  yosys -q -s "$od/syn.ys" >> "$od/yosys.log" 2>&1 || { echo "SYNFAIL"; return; }

  TOP="$d" PERIOD="$period" OUTDIR="$od" NETLIST="$od/${d}_net.v" \
    openroad -no_init -exit "$PNR" >> "$od/openroad.log" 2>&1
  grep -h "^OR_RESULT" "$od/openroad.log" | tail -1
}

run_one() {
  d="$1"
  base="$WORK/out/$d"
  if [ -f "$base/result.csv" ]; then echo "SKIP $d (already done)"; return 0; fi
  rm -rf "$base"; mkdir -p "$base"
  {
    # Probe, loosening until the design actually closes. Without this a design
    # slower than the first probe (sparkle needs >20 ns) would have its failing
    # probe recorded as the result, since the search only ever tightens.
    probe=20.0
    for _ in 1 2 3 4 5; do
      od="$base/p_$probe"; mkdir -p "$od"
      line=$(attempt "$d" "$probe" "$od")
      wns=$(sed -n 's/.*wns=\([-0-9.e]*\).*/\1/p' <<<"$line")
      [ -z "${wns:-}" ] && { echo "FAIL $d (probe at $probe)"; return 1; }
      echo "PROBE $d period=$probe $line"
      awk -v w="$wns" 'BEGIN{exit !(w>=0)}' && break
      probe=$(awk -v p="$probe" 'BEGIN{printf "%.3f", p*1.8}')
    done
    awk -v w="$wns" 'BEGIN{exit !(w>=0)}' || { echo "FAIL $d (never closed)"; return 1; }
    best_p="$probe"; best_line="$line"; best_od="$od"
    hi="$probe"; lo="0.2"
    try=$(awk -v p="$probe" -v w="$wns" 'BEGIN{v=(p-w)*1.02; if(v<0.3)v=0.3; printf "%.3f", v}')
    for i in $(seq 1 $((ITERS-1))); do
      awk -v h="$hi" -v l="$lo" 'BEGIN{exit !(h-l<0.02)}' && break
      awk -v t="$try" -v h="$hi" 'BEGIN{exit !(t>=h)}' && try=$(awk -v h="$hi" -v l="$lo" 'BEGIN{printf "%.3f",(h+l)/2}')
      od="$base/p_$try"; mkdir -p "$od"
      line=$(attempt "$d" "$try" "$od")
      w=$(sed -n 's/.*wns=\([-0-9.e]*\).*/\1/p' <<<"$line")
      echo "ITER $d $i period=$try $line"
      if [ -n "${w:-}" ] && awk -v w="$w" 'BEGIN{exit !(w>=0)}'; then
        hi="$try"; best_p="$try"; best_line="$line"; best_od="$od"
      else
        lo="$try"
      fi
      try=$(awk -v h="$hi" -v l="$lo" 'BEGIN{printf "%.3f",(h+l)/2}')
    done

    # use the winning attempt's own directory rather than rebuilding the
    # path from a formatted number
    log="$best_od/openroad.log"
    area=$(sed -n 's/.*area_um2=\([0-9.]*\).*/\1/p' <<<"$best_line")
    fmax=$(awk -v p="$best_p" 'BEGIN{printf "%.2f", 1000.0/p}')
    # report_power's Total row, column 5 = internal+switching+leakage, in W
    pw=$(awk '/^===SECTION power===/{f=1} f&&/^Total /{print $5; exit}' "$log")
    [ -z "${pw:-}" ] && pw=0
    pmw=$(awk -v p="$pw" 'BEGIN{printf "%.3f", p*1000}')
    # gate equivalents against sky130hd NAND2_1 = 3.7536 um^2 (PDK PROVENANCE.md)
    ge=$(awk -v a="$area" 'BEGIN{printf "%.0f", a/3.7536}')
    # report_clock_skew's "latency CRPR skew" triple
    skew=$(awk '/^===SECTION skew===/{f=1;next} /^===SECTION/{f=0}
                f && NF==3 && $1 ~ /^[0-9.]+$/ {print $3; exit}' "$log")
    echo "$d,$best_p,$fmax,$area,$ge,$pmw,${skew:-NA}" > "$base/result.csv"
    echo "DONE $d: $(cat "$base/result.csv")"
  } > "$WORK/logs/$d.log" 2>&1
  tail -1 "$WORK/logs/$d.log"
}
export -f run_one attempt
export WORK HERE ITERS TLEF SCLEF LIB UTIL DENSITY DONTUSE PNR SYNIN

echo "=== sky130 sweep: $ITERS iterations, $JOBS concurrent, util=$UTIL density=$DENSITY ==="
printf '%s\n' $DESIGNS | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}

OUT="$HERE/sky130_results.csv"
echo "design,period_ns,fmax_mhz,area_um2,gate_equiv,power_mw,clock_skew_ns" > "$OUT"
for d in $DESIGNS; do
  [ -f "$WORK/out/$d/result.csv" ] && cat "$WORK/out/$d/result.csv" >> "$OUT"
done
echo "=== SKY130 SWEEP COMPLETE -> $OUT ==="
cat "$OUT"
