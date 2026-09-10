# Vivado out-of-context flow with adaptive period search.
#
# One identical procedure for all eleven designs, so every row of the FPGA
# table comes from the same measurement -- see ../RESULTS.md.
#
# Inputs come from the environment (not -tclargs) because the repository path
# contains a space, which Vivado's tclargs parser splits on.
#   DESIGN  top module name (== file basename)
#   RTL     path to the .v
#   OUTDIR  where reports and the result CSV are written
#   ITERS   total flow runs: 1 probe + (ITERS-1) search steps

set design [file normalize $::env(DESIGN)]
set design $::env(DESIGN)
set rtl    $::env(RTL)
set outdir $::env(OUTDIR)
set iters  $::env(ITERS)

set part "xc7a12ticsg325-1L"
set_param general.maxThreads 1
file mkdir $outdir

proc run_at {design rtl part period outdir} {
    close_design -quiet
    set xdc [file join $outdir clk.xdc]
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
    close $fh

    read_verilog $rtl
    read_xdc $xdc
    synth_design -top $design -part $part -mode out_of_context
    opt_design
    place_design
    phys_opt_design
    route_design

    set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
    set wns 0
    if {[llength $paths] > 0} { set wns [get_property SLACK [lindex $paths 0]] }

    set regs [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]

    set unrouted [llength [get_nets -hier -filter {ROUTE_STATUS == UNROUTED}]]

    set tag [format %s_%s $design $period]
    report_utilization      -file [file join $outdir ${tag}_util.txt]

    # "Slice LUTs" from the utilization report, NOT a count of LUT primitives.
    # The two differ by up to 39% because Vivado packs two logic functions into
    # one dual-output LUT6; Slice LUTs is the conventional FPGA area metric and
    # is what published figures report.
    set luts 0
    set fh [open [file join $outdir ${tag}_util.txt] r]
    while {[gets $fh line] >= 0} {
        if {[regexp {^\|\s*Slice LUTs\s*\|\s*(\d+)} $line -> m]} { set luts $m; break }
    }
    close $fh
    report_timing_summary   -file [file join $outdir ${tag}_timing.txt]
    report_power            -file [file join $outdir ${tag}_power.txt]

    # total on-chip dynamic power, in W
    set pw 0
    set fh [open [file join $outdir ${tag}_power.txt] r]
    while {[gets $fh line] >= 0} {
        if {[regexp {Dynamic \(W\)\s*\|\s*([0-9.]+)} $line -> m]} { set pw $m }
    }
    close $fh

    return [list $wns $luts $regs $unrouted $pw]
}

# --- probe, loosening until the design actually closes ---------------------
# The search below only ever tightens, so a design slower than the first probe
# would otherwise have its failing probe recorded as the result.
set probe 25.0
for {set t 0} {$t < 5} {incr t} {
    set r [run_at $design $rtl $part $probe $outdir]
    puts "PROBE period=$probe wns=[lindex $r 0] luts=[lindex $r 1]"
    flush stdout
    if {[lindex $r 0] >= 0 && [lindex $r 3] == 0} { break }
    set probe [format %.3f [expr {$probe * 1.8}]]
}
if {[lindex $r 0] < 0} {
    puts "FAIL $design never closed by period $probe"
    exit 1
}

set best [concat [list $probe] [lrange $r 1 end]]
set hi   $probe
set lo   0.5
set try  [expr {($probe - [lindex $r 0]) * 1.02}]
if {$try < 1.0} { set try 1.0 }

# --- binary search for the tightest closing constraint --------------------
for {set i 1} {$i < $iters} {incr i} {
    if {$try >= $hi} { set try [expr {($lo + $hi) / 2.0}] }
    if {[expr {$hi - $lo}] < 0.02} { break }
    set try [format %.3f $try]
    set r [run_at $design $rtl $part $try $outdir]
    set w [lindex $r 0]
    set u [lindex $r 3]
    puts "ITER $i period=$try wns=$w unrouted=$u luts=[lindex $r 1]"
    flush stdout
    if {$w >= 0 && $u == 0} {
        set hi $try
        set best [concat [list $try] [lrange $r 1 end]]
    } else {
        set lo $try
    }
    set try [expr {($lo + $hi) / 2.0}]
}

set period [lindex $best 0]
set fmax   [expr {1000.0 / $period}]
set fh [open [file join $outdir ${design}_result.csv] w]
puts $fh "design,period_ns,fmax_mhz,luts,regs,unrouted,dyn_power_mw"
puts $fh "$design,$period,[format %.2f $fmax],[lindex $best 1],[lindex $best 2],[lindex $best 3],[format %.1f [expr {[lindex $best 4] * 1000.0}]]"
close $fh
puts "RESULT $design period=$period fmax=[format %.2f $fmax] luts=[lindex $best 1] regs=[lindex $best 2] power_mW=[format %.1f [expr {[lindex $best 4]*1000.0}]]"
exit 0
