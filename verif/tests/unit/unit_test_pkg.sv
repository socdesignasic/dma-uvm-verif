// -----------------------------------------------------------------------------
// unit_test_pkg : 모든 unit TB(tb_fifo / tb_skid / tb_adder)가 함께 쓰는 테스트
// TB top이 "dut_kind"(fifo|skid|adder)를 알려 주고, 그 값으로 모델을 고름.
//
//   +N_ITEMS=<n>  모든 테스트의 beat 개수를 덮어씀
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
