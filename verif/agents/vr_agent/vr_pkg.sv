// -----------------------------------------------------------------------------
// vr_pkg : 범용 valid/ready UVM agent (파일 하나에 클래스 하나, 아래에서 include)
//   VR_MASTER  : sequencer + master driver가 valid/data/side 구동
//   VR_SLAVE   : slave driver가 랜덤 backpressure로 ready 구동 (sequencer 없음)
//   VR_PASSIVE : monitor만
// -----------------------------------------------------------------------------
package vr_pkg;                                     // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함

  typedef virtual vr_if #(64) vr_vif;               // 64비트 virtual interface 타입 별칭
  typedef enum {VR_MASTER, VR_SLAVE, VR_PASSIVE} vr_mode_e;  // agent 모드 열거형

  `include "vr_item.sv"                             // beat item
  `include "vr_cfg.sv"                              // 설정
  `include "vr_sequencer.sv"                        // sequencer
  `include "vr_master_driver.sv"                    // master driver
  `include "vr_slave_driver.sv"                     // slave driver
  `include "vr_monitor.sv"                          // monitor
  `include "vr_agent.sv"                            // agent
  `include "vr_stream_seq.sv"                       // 랜덤 스트림 sequence
endpackage                                          // 패키지 끝
