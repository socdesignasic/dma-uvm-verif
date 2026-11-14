# Out-of-context synth + place + route of dma_ip_top (RTL from HW/), for a fast timing
# and utilization check without the block design.
#   vivado -mode batch -source ci/vivado/ooc.tcl -tclargs <out_dir> <period_ns>
set root   [file normalize [file join [file dirname [info script]] .. ..]]
set out    [file normalize [lindex $argv 0]]
set period [lindex $argv 1]
set part   xc7z020clg400-1
file mkdir $out

foreach f [lsort [glob -directory [file join $root HW] -types f */*.v */*/*.v]] { read_verilog $f }
# clock constraint generated with the requested period (a clock's PERIOD is read-only later)
set xdc [file join $out ooc_clock.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name ap_clk -period $period \[get_ports ap_clk\]"
close $fh
read_xdc -mode out_of_context $xdc
synth_design -top dma_ip_top -part $part -mode out_of_context
opt_design
place_design
route_design

report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_utilization                  -file [file join $out utilization.rpt]
report_methodology                  -file [file join $out methodology.rpt]
set setup [get_timing_paths -setup -max_paths 1 -nworst 1]
set hold  [get_timing_paths -hold  -max_paths 1 -nworst 1]
set fh [open [file join $out result.txt] w]
puts $fh "WNS=[get_property SLACK $setup]"
puts $fh "WHS=[get_property SLACK $hold]"
puts $fh "PERIOD=$period"
puts $fh "CRITICAL_PATH_FROM=[get_property STARTPOINT_PIN $setup]"
puts $fh "CRITICAL_PATH_TO=[get_property ENDPOINT_PIN $setup]"
close $fh
write_checkpoint -force [file join $out dma_ip_top_routed.dcp]
