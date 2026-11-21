// -----------------------------------------------------------------------------
// dma_test_pkg : dma_ip_top용 top 레벨 테스트 (파일 하나에 클래스 하나, 아래에서 include)
//   +N_JOBS=<n>   작업 기반 테스트의 DMA 작업 개수를 덮어씀
// -----------------------------------------------------------------------------
package dma_test_pkg;                               // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import axi4_slave_pkg::*;                           // AXI4 slave agent 패키지 import
  import dma_env_pkg::*;                            // top env 패키지 import
  import dma_seq_pkg::*;                            // top sequence 패키지 import

  `include "dma_base_test.svh"                       // 기본 테스트
  // 레지스터
  `include "dma_reg_reset_test.svh"                  // 리셋 값 테스트
  `include "dma_reg_bitbash_test.svh"                // bit-bash 테스트
  // DMA 작업
  `include "dma_smoke_test.svh"                      // smoke 테스트
  `include "dma_short_job_test.svh"                      // 작은 작업 테스트
  `include "dma_rand_test.svh"                       // 랜덤 테스트
  `include "dma_4kb_cross_test.svh"                        // 4KB 경계 테스트
  `include "dma_backpressure_test.svh"               // backpressure 테스트
  `include "dma_aw_backpressure_test.svh"            // AW backpressure 테스트 (BUG-002)
  `include "dma_irq_test.svh"                        // 인터럽트 테스트
  `include "dma_size_edge_test.svh"                  // 경계 크기 테스트
  `include "dma_long_job_test.svh"                      // 큰 작업 테스트
  `include "dma_irq_ready_test.svh"                  // IER = ready만 / 둘 다 x GIE 0/1 (ISR[1], AP_CTRL.ready)
  `include "dma_axil_timing_test.svh"                // AXI-Lite AW/W 순서, BREADY/RREADY 지연 (axil_cfg 노브)
  // 테스트 중간 리셋
  `include "dma_reset_test.svh"                      // idle 리셋, 마지막 B 전 리셋, interrupt 대기 중 리셋
  // 가설 확인 (directed)
  `include "dma_aw_wait_after_job_test.svh"          // H6: 정상 작업 뒤 AW 대기 (W FSM이 RUN에 남음)
  `include "dma_slow_b_test.svh"                     // H7: 느린 B (W->B FIFO 넘침)
  `include "dma_size_128mib_test.svh"                // H5: 128MiB 이상 transfer_byte (24비트 beat 카운터)
  `include "dma_busy_reg_write_test.svh"             // H3 + 작업 중 레지스터 쓰기, idle 확인 없는 연속 작업, in-place (PASS)
  `include "dma_reset_mid_job_test.svh"              // H4: 작업 도중 리셋 (adder에 남은 beat)
  `include "dma_start_busy_test.svh"                 // H1: 작업 중 start (대기하지 않고 버려짐)
  `include "dma_auto_restart_test.svh"               // H2: auto_restart (다시 시작하지 않음)
  // 검사기 자체 시험
  `include "dma_error_catcher.svh"                   // 예상 오류 catcher (dma_checker_test 전용)
  `include "dma_checker_test.svh"                    // checker self-test (결함 주입)
endpackage                                          // 패키지 끝
