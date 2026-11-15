// -----------------------------------------------------------------------------
// dma_seq_pkg : dma_ip_top용 sequence (파일 하나에 클래스 하나, 아래에서 include)
// 모두 AXI4-Lite sequencer(env.axil_agt.sqr)에서 돌고,
// dma_reg_map.sv의 주소로 axil_base_seq::write_reg()/read_reg()를 씁니다.
// -----------------------------------------------------------------------------
package dma_seq_pkg;                                // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import axil_pkg::*;                               // AXI4-Lite agent 패키지 import
  import axi4_slv_pkg::*;                           // AXI4 slave agent 패키지 import
  import dma_env_pkg::*;                            // top env 패키지 import

  `include "dma_job_seq.sv"                         // DMA 작업 sequence
  `include "dma_reg_reset_seq.sv"                   // 레지스터 리셋 값 검사 sequence
  `include "dma_reg_bitbash_seq.sv"                 // 레지스터 bit-bash sequence
endpackage                                          // 패키지 끝
