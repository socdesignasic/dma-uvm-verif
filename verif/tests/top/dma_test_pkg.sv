// -----------------------------------------------------------------------------
// dma_test_pkg : dma_ip_top용 top 레벨 테스트 (파일 하나에 클래스 하나, 아래에서 include)
//   +N_JOBS=<n>   작업 기반 테스트의 DMA 작업 개수를 덮어씀
// -----------------------------------------------------------------------------
package dma_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4_slv_pkg::*;
  import dma_env_pkg::*;
  import dma_seq_pkg::*;

  `include "dma_base_test.sv"
  // 레지스터
  `include "dma_reg_reset_test.sv"
  `include "dma_reg_bitbash_test.sv"
  // DMA 작업
  `include "dma_smoke_test.sv"
  `include "dma_small_test.sv"
  `include "dma_rand_test.sv"
  `include "dma_4kb_test.sv"
  `include "dma_backpressure_test.sv"
  `include "dma_aw_backpressure_test.sv"
  `include "dma_irq_test.sv"
  `include "dma_size_edge_test.sv"
  `include "dma_large_test.sv"
endpackage
