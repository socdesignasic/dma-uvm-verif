// -----------------------------------------------------------------------------
// unit_env_pkg : 입력과 출력 valid/ready 포트가 하나씩인 스트림 블록용
// 블록 레벨 env (sync_fifo, skid_buffer, axis_adder)
//
//   in_agt (STREAM_SOURCE) --> DUT --> out_agt (STREAM_SINK, 랜덤 backpressure)
//        \                             /
//         `--> scoreboard (순서대로 비교, 기준 모델) <--'
//         `--> coverage   (beat 값 + 사이클별 handshake 상태)
// -----------------------------------------------------------------------------
package unit_env_pkg;                               // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함
  import stream_pkg::*;                                 // valid/ready agent 패키지 import

  // 기준 모델 종류. 모든 unit 블록은 순서 유지, 손실 없음, 입력 1 : 출력 1.
  typedef enum {MODEL_PASS,    // FIFO, skid buffer: 출력 = 입력
                MODEL_ADD}     // axis_adder: lane_bw비트 lane마다 += side[lane_bw-1:0]
          model_e;                                  // 열거형 타입 이름

  `include "unit_env_cfg.svh"                        // env 설정
  `include "unit_scoreboard.svh"                     // scoreboard
  `include "unit_coverage.svh"                       // coverage
  `include "unit_env.svh"                            // env
endpackage                                          // 패키지 끝
