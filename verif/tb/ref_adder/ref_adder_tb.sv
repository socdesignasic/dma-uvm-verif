// -----------------------------------------------------------------------------
// P0 smoke TB: compiles the user's UVM reference (uvm_reference/) UNCHANGED
// under Vivado XSim. The reference was written for EDA Playground, which
// auto-imports UVM; XSim does not, so this wrapper provides the import.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
`include "testbench.sv"
