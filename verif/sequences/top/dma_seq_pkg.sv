// -----------------------------------------------------------------------------
// dma_seq_pkg : sequences for dma_ip_top (one class per file, included below)
// All run on the AXI4-Lite sequencer (env.axil_agt.sqr) and use
// axil_base_seq::write_reg()/read_reg() with the addresses in dma_reg_map.sv.
// -----------------------------------------------------------------------------
package dma_seq_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*;
  import axi4_slv_pkg::*;
  import dma_env_pkg::*;

  `include "dma_job_seq.sv"
  `include "dma_reg_reset_seq.sv"
  `include "dma_reg_bitbash_seq.sv"
endpackage
