// -----------------------------------------------------------------------------
// dma_env_pkg : dma_ip_top용 top 레벨 env (파일 하나에 클래스 하나, 아래에서 include)
//
//   axil_agt (AXI4-Lite master) ---> 제어 레지스터 ---> DUT ---> m00 AXI4 ---> mem_agt (slave + 메모리)
//                                                                     |
//   dma_scoreboard <-- AR/AW burst -----------------------------------'   + 작업마다 메모리 비교
//   dma_coverage   <-- 작업 + burst
//
// "작업(job)"은 DMA 실행 한 번 (verif/sequences/top/dma_job_seq.sv 참고): 레지스터 설정, 시작,
// 완료 대기(polling 또는 인터럽트), 그다음 모든 바이트에 대해  dst[i] == src[i] + value_to_add[7:0]
// 를 검사 (dma_ip_top은 adder를 C_ADDER_BIT_WIDTH = 8로 사용).
// -----------------------------------------------------------------------------
package dma_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*;
  import axi4_slv_pkg::*;

  localparam int unsigned GUARD   = 64;     // dst 앞뒤로 넘침을 검사하는 바이트 수
  localparam int unsigned BEAT    = 8;      // AXI beat 하나의 바이트 수
  localparam int unsigned LANE_BW = 8;      // dma_ip_top의 adder lane 폭

  typedef enum {DONE_POLL, DONE_IRQ} done_mode_e;

  `include "dma_reg_map.sv"
  `include "dma_job.sv"
  `include "dma_env_cfg.sv"
  `include "dma_scoreboard.sv"
  `include "dma_coverage.sv"
  `include "dma_env.sv"
endpackage
