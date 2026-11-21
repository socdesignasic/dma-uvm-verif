// -----------------------------------------------------------------------------
// dma_env_pkg : dma_ip_top용 top 레벨 env (파일 하나에 클래스 하나, 아래에서 include)
//
//   axil_agt (AXI4-Lite master) ---> 제어 레지스터 ---> DUT ---> m00 AXI4 ---> mem_agt (slave + 메모리)
//      |  ap                                                              |  ar/aw/w/b
//      '--> dma_predictor --> uvm_reg_predictor --> regmodel (mirror)     |
//              |  ^-- B ----------------------------------------------------+
//              '-- job --> dma_scoreboard <-- AR/AW burst, W, B ------------'   + 작업마다 메모리 비교
//   dma_coverage   <-- 검사를 끝낸 작업 (scoreboard done_ap) + burst
//
// "작업(job)"은 DMA 실행 한 번 (verif/top/seq/dma_job_vseq.svh, env.vsqr에서 실행): 레지스터 설정, 시작,
// 완료 대기(polling 또는 인터럽트), 그다음 모든 바이트에 대해  dst[i] == src[i] + value_to_add[7:0]
// 를 검사 (dma_ip_top은 adder를 C_ADDER_BIT_WIDTH = 8로 사용).
// -----------------------------------------------------------------------------
package dma_env_pkg;                                // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import axil_pkg::*;                               // AXI4-Lite agent 패키지 import
  import axi4_slave_pkg::*;                           // AXI4 slave agent 패키지 import

  localparam int unsigned GUARD   = 64;     // dst 앞뒤로 넘침을 검사하는 바이트 수
  localparam int unsigned BEAT    = 8;      // AXI beat 하나의 바이트 수
  localparam int unsigned LANE_BW = 8;      // dma_ip_top의 adder lane 폭

  typedef enum {DONE_POLL, DONE_IRQ} done_mode_e;   // 작업 완료 확인 방식: polling / 인터럽트
  typedef class dma_ref_model;                      // dma_job이 핸들을 가지므로 먼저 이름만 선언

  `include "dma_reg_map.svh"                         // 레지스터 주소와 비트 상수
  `include "dma_ap_ctrl_reg.svh"                     // RAL: AP_CTRL
  `include "dma_gie_reg.svh"                         // RAL: GIE
  `include "dma_ier_reg.svh"                         // RAL: IER
  `include "dma_isr_reg.svh"                         // RAL: ISR
  `include "dma_data_reg.svh"                        // RAL: 32비트 RW 데이터 레지스터 (6개가 같이 씀)
  `include "dma_reg_block.svh"                       // RAL: 레지스터 블록
  `include "dma_job.svh"                             // 작업 객체
  `include "dma_ref_model.svh"                       // 참조 모델 (job의 기대 burst 목록, W 데이터, 스냅샷)
  `include "dma_env_cfg.svh"                         // env 설정
  `include "dma_predictor.svh"                       // predictor (start 순간 job 생성, B로 완료)
  `include "dma_scoreboard.svh"                      // scoreboard
  `include "dma_coverage.svh"                        // coverage
  `include "dma_vsqr.svh"                            // job virtual sequencer
  `include "dma_env.svh"                             // env
endpackage                                          // 패키지 끝
