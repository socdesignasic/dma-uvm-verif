# 전체 시스템 빌드: Zynq PS7 + dma_ip_top block design -> 비트스트림 + XSA.
# block design은 ci/vivado/bd/design_1.tcl에서 가져옴 (손으로 만든 프로젝트에서 export).
# IP는 scripts/fpga.py가 HW/ + ci/vivado/ip/로 조립한 IP repo에서 가져옴.
#   vivado -mode batch -source ci/vivado/build_system.tcl -tclargs <out_dir> <ip_repo> <jobs> [strategy] [part]
set root    [file normalize [file join [file dirname [info script]] .. ..]]  ;# 저장소 루트 (이 스크립트의 두 단계 위)
set out     [file normalize [lindex $argv 0]]               ;# 첫 인자: 출력 디렉터리
set ip_repo [file normalize [lindex $argv 1]]               ;# 둘째 인자: IP repo
set jobs    [lindex $argv 2]                                ;# 셋째 인자: 병렬 작업 수
set part    [expr {[llength $argv] > 4 ? [lindex $argv 4] : "xc7z020clg400-1"}]  ;# 다섯째 인자: FPGA 부품 (기본 Zybo Z7-20)

create_project -force sys [file join $out proj] -part $part  ;# 프로젝트 생성 (있으면 덮어씀)
set_property ip_repo_paths [list $ip_repo] [current_project]  ;# IP repo 경로 등록
update_ip_catalog                                           ;# IP 카탈로그 갱신
if {[llength [get_ipdefs -quiet xilinx.com:user:dma_ip_top:*]] == 0} {  ;# DMA IP가 카탈로그에 없으면
  error "dma_ip_top not found in IP repo $ip_repo"    ;# 오류로 멈춤
}                                                           ;# if 끝

source [file join $root ci vivado bd design_1.tcl]          ;# block design 재생성 스크립트 실행
validate_bd_design                                          ;# block design 검증
save_bd_design                                              ;# 저장
set bd [get_files design_1.bd]                              ;# block design 파일
generate_target all $bd                                     ;# 출력 파일 생성
set wrapper [make_wrapper -files $bd -top]                  ;# HDL wrapper 생성
add_files -norecurse $wrapper                               ;# wrapper를 프로젝트에 추가
set_property top design_1_wrapper [current_fileset]         ;# top 모듈 지정
update_compile_order -fileset sources_1                     ;# 컴파일 순서 갱신

# 구현 전략 (RTL / block design은 바꾸지 않음): 배치와 배선을 더 열심히 탐색하고,
# 배선 후 physical optimization을 실행. 기본 전략으로는 100 MHz에 약 0.2-0.35 ns 모자람
# (BUGS.md NOTE-001. 손으로 만든 프로젝트도 WNS -0.201 ns였음).
set impl_strategy [expr {[llength $argv] > 3 ? [lindex $argv 3] : "Performance_ExplorePostRoutePhysOpt"}]  ;# 넷째 인자가 있으면 그 전략, 없으면 기본 탐색 전략
if {$impl_strategy ne "default"} {                          ;# default가 아니면
  if {[catch {set_property strategy $impl_strategy [get_runs impl_1]} msg]} {  ;# 전략 설정 시도
    puts "WARNING: strategy '$impl_strategy' not available ($msg); using Performance_Explore"  ;# 없는 전략이면 경고
    set impl_strategy Performance_Explore                   ;# 대체 전략
    set_property strategy $impl_strategy [get_runs impl_1]  ;# 대체 전략 설정
  }                                                         ;# catch 끝
  set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED            true [get_runs impl_1]  ;# 배치 후 physical optimization 켜기
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]  ;# 배선 후 physical optimization 켜기
}                                                           ;# if 끝
puts "IMPL_STRATEGY=$impl_strategy"                         ;# 사용한 전략 출력
launch_runs impl_1 -to_step write_bitstream -jobs $jobs     ;# 구현부터 비트스트림까지 실행
wait_on_run impl_1                                          ;# 끝날 때까지 대기
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {  ;# 100%가 아니면
  error "impl_1 did not complete: [get_property STATUS [get_runs impl_1]]"  ;# 오류로 멈춤
}                                                           ;# if 끝
open_run impl_1                                             ;# 구현 결과 열기
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]  ;# 타이밍 요약 보고서
report_utilization                  -file [file join $out utilization.rpt]  ;# 사용량 보고서
set setup [get_timing_paths -setup -max_paths 1 -nworst 1]  ;# setup 최악 경로
set hold  [get_timing_paths -hold  -max_paths 1 -nworst 1]  ;# hold 최악 경로
set fh [open [file join $out result.txt] w]                 ;# 결과 파일 열기
puts $fh "WNS=[get_property SLACK $setup]"                  ;# setup 여유
puts $fh "WHS=[get_property SLACK $hold]"                   ;# hold 여유
puts $fh "CRITICAL_PATH_FROM=[get_property STARTPOINT_PIN $setup]"  ;# 임계 경로 시작점
puts $fh "CRITICAL_PATH_TO=[get_property ENDPOINT_PIN $setup]"  ;# 임계 경로 끝점
puts $fh "IMPL_STRATEGY=$impl_strategy"                     ;# 구현 전략
close $fh                                                   ;# 파일 닫기

set bit [lindex [glob [file join $out proj sys.runs impl_1 *.bit]] 0]  ;# 생성된 비트스트림 찾기
file copy -force $bit [file join $out design_1_wrapper.bit]  ;# 출력 디렉터리로 복사
write_hw_platform -fixed -include_bit -force -file [file join $out design_1_wrapper.xsa]  ;# 비트스트림 포함 XSA 생성 (Vitis용)
