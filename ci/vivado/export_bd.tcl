# 한 번만 실행: 손으로 만든 Vivado 프로젝트의 block design을 다시 만들 수 있는 TCL로 export.
# 프로젝트를 읽기 전용으로 열기 때문에 mem_copy_vivado/ 안은 아무것도 바뀌지 않음.
#   vivado -mode batch -source ci/vivado/export_bd.tcl
set root [file normalize [file join [file dirname [info script]] .. ..]]
open_project -read_only [file join $root mem_copy_vivado mem_copy_vivado.xpr]
puts "BOARD_PART=[get_property board_part [current_project]]"
puts "BOARDS_AVAILABLE=[llength [get_board_parts -quiet *zybo-z7-20*]]"
open_bd_design [get_files design_1.bd]
write_bd_tcl -force -no_ip_version [file join $root ci vivado bd design_1.tcl]
foreach c [get_bd_cells] { puts "CELL [get_property VLNV $c] $c" }
foreach a [get_bd_addr_segs -excluded false -of_objects [get_bd_addr_spaces]] {
  puts "ADDR $a [get_property OFFSET $a] [get_property RANGE $a]"
}
close_project
