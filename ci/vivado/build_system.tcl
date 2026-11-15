# 전체 시스템 빌드: Zynq PS7 + dma_ip_top block design -> 비트스트림 + XSA.
# block design은 ci/vivado/bd/design_1.tcl에서 가져옴 (손으로 만든 프로젝트에서 export).
# IP는 scripts/fpga.py가 HW/ + ci/vivado/ip/로 조립한 IP repo에서 가져옴.
#   vivado -mode batch -source ci/vivado/build_system.tcl -tclargs <out_dir> <ip_repo> <jobs>
set root    [file normalize [file join [file dirname [info script]] .. ..]]
set out     [file normalize [lindex $argv 0]]
set ip_repo [file normalize [lindex $argv 1]]
set jobs    [lindex $argv 2]
set part    xc7z020clg400-1

create_project -force sys [file join $out proj] -part $part
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog
if {[llength [get_ipdefs -quiet xilinx.com:user:dma_ip_top:*]] == 0} {
  error "dma_ip_top not found in IP repo $ip_repo"
}

source [file join $root ci vivado bd design_1.tcl]
validate_bd_design
save_bd_design
set bd [get_files design_1.bd]
generate_target all $bd
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# 구현 전략 (RTL / block design은 바꾸지 않음): 배치와 배선을 더 열심히 탐색하고,
# 배선 후 physical optimization을 실행. 기본 전략으로는 100 MHz에 약 0.2-0.35 ns 모자람
# (BUGS.md NOTE-001. 손으로 만든 프로젝트도 WNS -0.201 ns였음).
set impl_strategy [expr {[llength $argv] > 3 ? [lindex $argv 3] : "Performance_ExplorePostRoutePhysOpt"}]
if {$impl_strategy ne "default"} {
  if {[catch {set_property strategy $impl_strategy [get_runs impl_1]} msg]} {
    puts "WARNING: strategy '$impl_strategy' not available ($msg); using Performance_Explore"
    set impl_strategy Performance_Explore
    set_property strategy $impl_strategy [get_runs impl_1]
  }
  set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED            true [get_runs impl_1]
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
}
puts "IMPL_STRATEGY=$impl_strategy"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 did not complete: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_utilization                  -file [file join $out utilization.rpt]
set setup [get_timing_paths -setup -max_paths 1 -nworst 1]
set hold  [get_timing_paths -hold  -max_paths 1 -nworst 1]
set fh [open [file join $out result.txt] w]
puts $fh "WNS=[get_property SLACK $setup]"
puts $fh "WHS=[get_property SLACK $hold]"
puts $fh "CRITICAL_PATH_FROM=[get_property STARTPOINT_PIN $setup]"
puts $fh "CRITICAL_PATH_TO=[get_property ENDPOINT_PIN $setup]"
puts $fh "IMPL_STRATEGY=$impl_strategy"
close $fh

set bit [lindex [glob [file join $out proj sys.runs impl_1 *.bit]] 0]
file copy -force $bit [file join $out design_1_wrapper.bit]
write_hw_platform -fixed -include_bit -force -file [file join $out design_1_wrapper.xsa]
