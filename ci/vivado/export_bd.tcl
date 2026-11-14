# One-time: export the block design of the hand-made Vivado project to a re-creatable TCL.
# The project is opened READ-ONLY, so nothing in mem_copy_vivado/ is modified.
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
