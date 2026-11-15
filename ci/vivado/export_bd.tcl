# 한 번만 실행: 손으로 만든 Vivado 프로젝트의 block design을 다시 만들 수 있는 TCL로 export.
# 프로젝트를 읽기 전용으로 열기 때문에 mem_copy_vivado/ 안은 아무것도 바뀌지 않음.
#   vivado -mode batch -source ci/vivado/export_bd.tcl
set root [file normalize [file join [file dirname [info script]] .. ..]]  ;# 저장소 루트
open_project -read_only [file join $root mem_copy_vivado mem_copy_vivado.xpr]  ;# 손으로 만든 프로젝트를 읽기 전용으로 열기
puts "BOARD_PART=[get_property board_part [current_project]]"  ;# 보드 부품 출력
puts "BOARDS_AVAILABLE=[llength [get_board_parts -quiet *zybo-z7-20*]]"  ;# Zybo Z7-20 보드 파일 설치 여부 출력
open_bd_design [get_files design_1.bd]                      ;# block design 열기
write_bd_tcl -force -no_ip_version [file join $root ci vivado bd design_1.tcl]  ;# 재생성 Tcl로 export (IP 버전 고정 안 함)
foreach c [get_bd_cells] { puts "CELL [get_property VLNV $c] $c" }  ;# block design 셀마다 VLNV 출력
foreach a [get_bd_addr_segs -excluded false -of_objects [get_bd_addr_spaces]] {  ;# 주소 구간마다
  puts "ADDR $a [get_property OFFSET $a] [get_property RANGE $a]"  ;# 이름, 시작 주소, 크기 출력
}                                                           ;# foreach 끝
close_project                                               ;# 프로젝트 닫기
