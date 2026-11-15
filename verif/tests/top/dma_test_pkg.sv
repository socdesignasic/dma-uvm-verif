// -----------------------------------------------------------------------------
// dma_test_pkg : dma_ip_top용 top 레벨 테스트 (파일 하나에 클래스 하나, 아래에서 include)
//   +N_JOBS=<n>   작업 기반 테스트의 DMA 작업 개수를 덮어씀
// -----------------------------------------------------------------------------
package dma_test_pkg;                               // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import axi4_slv_pkg::*;                           // AXI4 slave agent 패키지 import
  import dma_env_pkg::*;                            // top env 패키지 import
  import dma_seq_pkg::*;                            // top sequence 패키지 import

  `include "dma_base_test.sv"                       // 기본 테스트
  // 레지스터
  `include "dma_reg_reset_test.sv"                  // 리셋 값 테스트
  `include "dma_reg_bitbash_test.sv"                // bit-bash 테스트
  // DMA 작업
  `include "dma_smoke_test.sv"                      // smoke 테스트
  `include "dma_small_test.sv"                      // 작은 작업 테스트
  `include "dma_rand_test.sv"                       // 랜덤 테스트
  `include "dma_4kb_test.sv"                        // 4KB 경계 테스트
  `include "dma_backpressure_test.sv"               // backpressure 테스트
  `include "dma_aw_backpressure_test.sv"            // AW backpressure 테스트 (BUG-002)
  `include "dma_irq_test.sv"                        // 인터럽트 테스트
  `include "dma_size_edge_test.sv"                  // 경계 크기 테스트
  `include "dma_large_test.sv"                      // 큰 작업 테스트
endpackage                                          // 패키지 끝
