// -----------------------------------------------------------------------------
// dma_seq_pkg : dma_ip_top용 sequence (파일 하나에 클래스 하나, 아래에서 include)
//   dma_job_vseq         : virtual sequencer(env.vsqr)에서 돌고, 레지스터는 regmodel(RAL) frontdoor, 메모리는 백도어로 씀
//   dma_pipeline_vseq    : dma_job_vseq의 단계로 job을 idle 확인 없이 잇달아 실행
//   dma_busy_reg_vseq    : 작업 중 레지스터 10개 쓰기(다음 job 값, ISR, AP_CTRL=0)와 다시 읽기
//   dma_reg_bitbash_vseq : virtual sequencer(env.vsqr)에서 RAL 내장 bit-bash sequence를 돌림
//   dma_reset_vseq       : AXI-Lite를 lock하고 진행 중 접근이 끝난 뒤 테스트 중간 리셋 한 번 (vsqr.rst_vif)
//   (리셋 값 검사는 RAL 내장 uvm_reg_hw_reset_seq를 test가 직접 돌림)
// -----------------------------------------------------------------------------
package dma_seq_pkg;                                // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import axil_pkg::*;                               // AXI4-Lite agent 패키지 import
  import axi4_slave_pkg::*;                           // AXI4 slave agent 패키지 import
  import dma_env_pkg::*;                            // top env 패키지 import

  `include "dma_job_vseq.svh"                        // DMA 작업 virtual sequence
  `include "dma_pipeline_vseq.svh"                   // idle 확인 없는 연속 작업 (다음 작업 레지스터를 작업 중에)
  `include "dma_busy_reg_vseq.svh"                   // 작업 중 레지스터 10개 쓰기와 다시 읽기
  `include "dma_reg_bitbash_vseq.svh"                // 레지스터 bit-bash virtual sequence (RAL 내장)
  `include "dma_reset_vseq.svh"                      // 테스트 중간 리셋 virtual sequence
endpackage                                          // 패키지 끝
