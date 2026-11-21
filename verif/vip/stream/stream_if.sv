// -----------------------------------------------------------------------------
// stream_if : 범용 valid/ready 스트림 인터페이스 (데이터 64비트 + sideband 32비트)
//   side : beat와 함께 샘플링되는 sideband
//          (axis_adder: ctrl_constant. FIFO / skid buffer는 무시)
// 프로토콜 검사(SVA)는 UVM으로 보고하므로 sim.py가 UVM_ERROR로 셉니다.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"                           // `uvm_error 매크로를 쓰기 위해 포함

interface stream_if #(parameter int DW = 64) (input logic clk, input logic rst);  // 데이터 폭 파라미터 (기본 64), 클럭과 active-high 리셋
  import uvm_pkg::*;                                // SVA에서 UVM 보고 함수를 쓰기 위해 import

  logic          valid;                             // 데이터가 유효함
  logic          ready;                             // 받는 쪽이 받을 준비됨
  logic [DW-1:0] data;                              // 데이터
  logic [31:0]   side;                              // sideband

  bit chk_en = 1'b1;   // 프로토콜 검사 켜기/끄기 (예: 오류 주입 테스트)

  // master 쪽 (TB가 valid/data/side 구동)
  clocking mcb @(posedge clk);                      // 클럭 상승 에지 기준 clocking block
    default input #1step output #1;                 // 입력은 에지 직전 값, 출력은 에지 1 time unit 뒤
    output valid, data, side;                       // TB가 구동하는 신호
    input  ready;                                   // DUT가 구동하는 ready
  endclocking                                       // clocking block 끝

  // slave 쪽 (TB가 ready 구동)
  clocking scb @(posedge clk);                      // 클럭 상승 에지 기준 clocking block
    default input #1step output #1;                 // 입력은 에지 직전 값, 출력은 에지 1 time unit 뒤
    output ready;                                   // TB가 구동하는 ready
    input  valid, data;                             // DUT가 구동하는 신호
  endclocking                                       // clocking block 끝

  // 수동 monitor
  clocking moncb @(posedge clk);                    // monitor 전용 clocking block
    default input #1step;                           // 입력만 있음
    input valid, ready, data, side, rst;            // handshake, 데이터, sideband, 리셋 샘플
  endclocking                                       // clocking block 끝

  // ---------------- 프로토콜 assertion ----------------
  // valid가 1이 되면 받아들여질 때까지 1을 유지하고 data도 바뀌면 안 됨
  a_hold : assert property (@(posedge clk) disable iff (rst || !chk_en)  // 유지 검사 (리셋 중이거나 검사 꺼짐이면 무시)
             (valid && !ready) |=> (valid && $stable(data)))  // 받아들여지기 전엔 valid 유지, data 고정
    else `uvm_error("VR_SVA", $sformatf("%m: valid dropped or data changed before handshake"))  // 위반 시 UVM_ERROR (%m = 인스턴스 경로)

  a_valid_known : assert property (@(posedge clk) disable iff (rst || !chk_en)  // valid X/Z 검사
             !$isunknown(valid))                    // valid에 X/Z가 없어야 함
    else `uvm_error("VR_SVA", $sformatf("%m: valid is X/Z"))  // 위반 시 UVM_ERROR

  a_ready_known : assert property (@(posedge clk) disable iff (rst || !chk_en)  // ready X/Z 검사
             !$isunknown(ready))                    // ready에 X/Z가 없어야 함
    else `uvm_error("VR_SVA", $sformatf("%m: ready is X/Z"))  // 위반 시 UVM_ERROR

  a_data_known : assert property (@(posedge clk) disable iff (rst || !chk_en)  // data X/Z 검사
             valid |-> !$isunknown(data))           // valid일 때 data에 X/Z가 없어야 함
    else `uvm_error("VR_SVA", $sformatf("%m: data is X/Z while valid"))  // 위반 시 UVM_ERROR

endinterface                                        // 인터페이스 끝
