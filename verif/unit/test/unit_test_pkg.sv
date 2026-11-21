// -----------------------------------------------------------------------------
// unit_test_pkg : 모든 unit TB(tb_fifo / tb_skid / tb_adder)가 함께 쓰는 테스트
// TB top이 "dut_kind"(fifo|skid|adder)를 알려 주고, 그 값으로 모델을 고름.
//
//   +N_ITEMS=<n>  모든 테스트의 beat 개수를 덮어씀
// -----------------------------------------------------------------------------
package unit_test_pkg;                              // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import stream_pkg::*;                                 // valid/ready agent 패키지 import
  import unit_env_pkg::*;                           // unit env 패키지 import

  `include "unit_base_test.svh"                      // 기본 테스트
  `include "unit_smoke_test.svh"                     // smoke 테스트
  `include "unit_post_reset_test.svh"                // 리셋 직후 테스트 (BUG-001)
  `include "unit_single_beat_test.svh"               // beat 1개 테스트
  `include "unit_rand_test.svh"                      // 랜덤 테스트
  `include "unit_backpressure_test.svh"              // backpressure 테스트
  `include "unit_sparse_input_test.svh"                   // 띄엄띄엄 입력 테스트
  `include "unit_fixed_value_test.svh"                // side 고정 테스트
endpackage                                          // 패키지 끝
