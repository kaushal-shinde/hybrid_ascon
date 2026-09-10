# OpenROAD place-and-route on sky130hd, hand-rolled.
#
# The vendored ~/pdks/sky130hd platform is a partial copy of the ORFS platform
# (lef/, lib/, tapcell.tcl, config.mk only) and OpenROAD-flow-scripts is not
# installed here, so this reproduces the ORFS RTL-to-routed sequence directly.
# It stops after global routing: area, timing and power are all available
# there, and detailed routing would need the PDN config that was not copied.
#
# All inputs arrive through the environment; see run_sky130.sh.

set top     $::env(TOP)
set period  $::env(PERIOD)
set outdir  $::env(OUTDIR)

read_lef $::env(TLEF)
read_lef $::env(SCLEF)
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design $top

create_clock -name clk -period $period [get_ports clk]
set_wire_rc -signal -layer met2
set_wire_rc -clock  -layer met3

# ---------------------------------------------------------------- floorplan
initialize_floorplan -utilization $::env(UTIL) -aspect_ratio 1.0 \
                     -core_space 2.0 -site unithd

# Routing tracks. ORFS ships these as the platform's make_tracks.tcl, which is
# absent from the vendored PDK copy; the pitches/offsets below are read back
# from sky130_fd_sc_hd.tlef's own LAYER definitions.
make_tracks li1  -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met1 -x_offset 0.17 -x_pitch 0.34 -y_offset 0.17 -y_pitch 0.34
make_tracks met2 -x_offset 0.23 -x_pitch 0.46 -y_offset 0.23 -y_pitch 0.46
make_tracks met3 -x_offset 0.34 -x_pitch 0.68 -y_offset 0.34 -y_pitch 0.68
make_tracks met4 -x_offset 0.46 -x_pitch 0.92 -y_offset 0.46 -y_pitch 0.92
make_tracks met5 -x_offset 1.70 -x_pitch 3.40 -y_offset 1.70 -y_pitch 3.40

place_pins -hor_layers met3 -ver_layers met2
tapcell -distance 14 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1

# ------------------------------------------------------------------- place
global_placement -density $::env(DENSITY)
estimate_parasitics -placement
repair_design
detailed_placement

# --------------------------------------------------------------------- CTS
set clkbufs "sky130_fd_sc_hd__clkbuf_1 sky130_fd_sc_hd__clkbuf_2 \
             sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8 \
             sky130_fd_sc_hd__clkbuf_16"
clock_tree_synthesis -buf_list $clkbufs -root_buf sky130_fd_sc_hd__clkbuf_16 \
                     -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_timing
detailed_placement

# ------------------------------------------------------------------- route
set_routing_layers -signal met1-met5 -clock met3-met5
global_route
estimate_parasitics -global_routing

# ----------------------------------------------------------------- reports
# OpenROAD's own commands don't accept "> file" redirection, so everything goes
# to stdout under section markers; run_sky130.sh captures and parses the log.
puts "===SECTION area==="
report_design_area
puts "===SECTION timing==="
report_checks -path_delay max -fields {slew cap input net fanout} -digits 4
puts "===SECTION tns==="
report_tns
puts "===SECTION skew==="
report_clock_skew
puts "===SECTION power==="
report_power
puts "===SECTION cells==="
report_cell_usage
puts "===SECTION end==="

# Sum placed instance areas straight out of OpenDB -- rsz::design_area is not
# available in this build, and this is the same quantity report_design_area
# prints, without having to parse it back.
set block [[[ord::get_db] getChip] getBlock]
set dbu   [$block getDefUnits]
set area_dbu 0
foreach inst [$block getInsts] {
    set m [$inst getMaster]
    set area_dbu [expr {$area_dbu + [$m getWidth] * [$m getHeight]}]
}
set area_um2 [expr {double($area_dbu) / ($dbu * $dbu)}]

set wns [sta::worst_slack -max]
puts "OR_RESULT top=$top period=$period wns=$wns area_um2=[format %.2f $area_um2] insts=[llength [$block getInsts]]"
exit 0
