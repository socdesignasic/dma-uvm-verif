// -----------------------------------------------------------------------------
// dma_test_pkg : top-level tests for dma_ip_top (one class per file, included below)
//   +N_JOBS=<n>   overrides the number of DMA jobs for job-based tests
// -----------------------------------------------------------------------------
package dma_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4_slv_pkg::*;
  import dma_env_pkg::*;
  import dma_seq_pkg::*;

  `include "dma_base_test.sv"
  // registers
  `include "dma_reg_reset_test.sv"
  `include "dma_reg_bitbash_test.sv"
  // DMA jobs
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
