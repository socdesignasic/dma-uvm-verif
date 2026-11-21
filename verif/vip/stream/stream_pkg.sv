// -----------------------------------------------------------------------------
// stream_pkg : 범용 valid/ready UVM agent (파일 하나에 클래스 하나, 아래에서 include)
//   STREAM_SOURCE  : sequencer + master driver가 valid/data/side 구동
//   STREAM_SINK   : slave driver가 랜덤 backpressure로 ready 구동 (sequencer 없음)
//   STREAM_PASSIVE : monitor만
// -----------------------------------------------------------------------------
package stream_pkg;                                     // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함

  typedef virtual stream_if #(64) stream_vif;               // 64비트 virtual interface 타입 별칭
  typedef enum {STREAM_SOURCE, STREAM_SINK, STREAM_PASSIVE} stream_mode_e;  // agent 모드 열거형

  `include "stream_item.svh"                             // beat item
  `include "stream_cfg.svh"                              // 설정
  `include "stream_sequencer.svh"                        // sequencer
  `include "stream_source_driver.svh"                    // master driver
  `include "stream_sink_driver.svh"                     // slave driver
  `include "stream_monitor.svh"                          // monitor
  `include "stream_agent.svh"                            // agent
  `include "stream_rand_seq.svh"                       // 랜덤 스트림 sequence
endpackage                                          // 패키지 끝
