// -----------------------------------------------------------------------------
// unit_env_pkg : 입력과 출력 valid/ready 포트가 하나씩인 스트림 블록용
// 블록 레벨 env (sync_fifo, skid_buffer, axis_adder)
//
//   in_agt (VR_MASTER) --> DUT --> out_agt (VR_SLAVE, 랜덤 backpressure)
//        \                             /
//         `--> scoreboard (순서대로 비교, 기준 모델) <--'
//         `--> coverage   (beat 값 + 사이클별 handshake 상태)
// -----------------------------------------------------------------------------
package unit_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vr_pkg::*;

  // 기준 모델 종류. 모든 unit 블록은 순서 유지, 손실 없음, 입력 1 : 출력 1.
  typedef enum {MODEL_PASS,    // FIFO, skid buffer: 출력 = 입력
                MODEL_ADD}     // axis_adder: lane_bw비트 lane마다 += side[lane_bw-1:0]
          model_e;

  `include "unit_env_cfg.sv"
  `include "unit_scoreboard.sv"
  `include "unit_coverage.sv"
  `include "unit_env.sv"
endpackage
