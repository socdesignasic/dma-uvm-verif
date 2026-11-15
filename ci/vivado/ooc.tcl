# dma_ip_top(HW/의 RTL)를 단독(out-of-context)으로 합성 + 배치 + 배선.
# block design 없이 타이밍과 사용량을 빠르게 확인하는 용도.
#   vivado -mode batch -source ci/vivado/ooc.tcl -tclargs <out_dir> <period_ns>
set root   [file normalize [file join [file dirname [info script]] .. ..]]
set out    [file normalize [lindex $argv 0]]
set period [lindex $argv 1]
set part   xc7z020clg400-1
file mkdir $out

foreach f [lsort [glob -directory [file join $root HW] -types f */*.v */*/*.v]] { read_verilog $f }
# 요청한 주기로 클럭 제약을 생성 (클럭의 PERIOD는 나중에 바꿀 수 없음)
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
