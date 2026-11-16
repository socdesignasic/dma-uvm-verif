# dma_ip_top(HW/의 RTL)를 단독(out-of-context)으로 합성 + 배치 + 배선.
# block design 없이 타이밍과 사용량을 빠르게 확인하는 용도.
#   vivado -mode batch -source ci/vivado/ooc.tcl -tclargs <out_dir> <period_ns> [part]
set root   [file normalize [file join [file dirname [info script]] .. ..]]  ;# 저장소 루트
set out    [file normalize [lindex $argv 0]]                ;# 첫 인자: 출력 디렉터리
set period [lindex $argv 1]                                 ;# 둘째 인자: 클럭 주기 (ns)
set part   [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xc7z020clg400-1"}]  ;# 셋째 인자: FPGA 부품 (기본 Zybo Z7-20)
file mkdir $out                                             ;# 출력 디렉터리 생성

foreach f [lsort [glob -directory [file join $root HW] -types f */*.v */*/*.v]] { read_verilog $f }  ;# HW/ 아래 모든 .v 파일 읽기
# 요청한 주기로 클럭 제약을 생성 (클럭의 PERIOD는 나중에 바꿀 수 없음)
set xdc [file join $out ooc_clock.xdc]                      ;# 클럭 제약 파일 경로
set fh [open $xdc w]                                        ;# 파일 열기
puts $fh "create_clock -name ap_clk -period $period \[get_ports ap_clk\]"  ;# ap_clk 클럭 생성 제약 쓰기
close $fh                                                   ;# 파일 닫기
read_xdc -mode out_of_context $xdc                          ;# out-of-context 제약으로 읽기
synth_design -top dma_ip_top -part $part -mode out_of_context  ;# 합성 (top 모듈, out-of-context)
opt_design                                                  ;# 논리 최적화
place_design                                                ;# 배치
route_design                                                ;# 배선

report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]  ;# 타이밍 요약 보고서
report_utilization                  -file [file join $out utilization.rpt]  ;# 사용량 보고서
report_methodology                  -file [file join $out methodology.rpt]  ;# 설계 방법론 검사 보고서
set setup [get_timing_paths -setup -max_paths 1 -nworst 1]  ;# setup 최악 경로
set hold  [get_timing_paths -hold  -max_paths 1 -nworst 1]  ;# hold 최악 경로
set fh [open [file join $out result.txt] w]                 ;# 결과 파일 열기
puts $fh "WNS=[get_property SLACK $setup]"                  ;# setup 여유
puts $fh "WHS=[get_property SLACK $hold]"                   ;# hold 여유
puts $fh "PERIOD=$period"                                   ;# 클럭 주기
puts $fh "CRITICAL_PATH_FROM=[get_property STARTPOINT_PIN $setup]"  ;# 임계 경로 시작점
puts $fh "CRITICAL_PATH_TO=[get_property ENDPOINT_PIN $setup]"  ;# 임계 경로 끝점
close $fh                                                   ;# 파일 닫기
write_checkpoint -force [file join $out dma_ip_top_routed.dcp]  ;# 배선 결과 checkpoint 저장
