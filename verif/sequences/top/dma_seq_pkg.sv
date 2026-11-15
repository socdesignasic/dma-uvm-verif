// -----------------------------------------------------------------------------
// dma_seq_pkg : dma_ip_top용 sequence (파일 하나에 클래스 하나, 아래에서 include)
// 모두 AXI4-Lite sequencer(env.axil_agt.sqr)에서 돌고,
// dma_reg_map.sv의 주소로 axil_base_seq::write_reg()/read_reg()를 씁니다.
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
