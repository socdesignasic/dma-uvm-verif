// -----------------------------------------------------------------------------
// unit_test_pkg : tests shared by all unit TBs (tb_fifo / tb_skid / tb_adder)
// The TB top publishes "dut_kind" (fifo|skid|adder) which selects the model.
//
//   +N_ITEMS=<n>  overrides the number of beats for any test
// -----------------------------------------------------------------------------
package unit_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vr_pkg::*;
  import unit_env_pkg::*;

  `include "unit_base_test.sv"
  `include "unit_smoke_test.sv"
  `include "unit_post_reset_test.sv"
  `include "unit_rand_test.sv"
  `include "unit_backpressure_test.sv"
  `include "unit_trickle_test.sv"
  `include "unit_fixed_side_test.sv"
endpackage
