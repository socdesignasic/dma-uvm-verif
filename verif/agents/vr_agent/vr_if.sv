// -----------------------------------------------------------------------------
// vr_if : 범용 valid/ready 스트림 인터페이스 (데이터 64비트 + sideband 32비트)
//   side : beat와 함께 샘플링되는 sideband
//          (axis_adder: ctrl_constant. FIFO / skid buffer는 무시)
// 프로토콜 검사(SVA)는 UVM으로 보고하므로 sim.py가 UVM_ERROR로 셉니다.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"

interface vr_if #(parameter int DW = 64) (input logic clk, input logic rst);
  import uvm_pkg::*;

  logic          valid;
  logic          ready;
  logic [DW-1:0] data;
  logic [31:0]   side;

  bit chk_en = 1'b1;   // 프로토콜 검사 켜기/끄기 (예: 오류 주입 테스트)

  // master 쪽 (TB가 valid/data/side 구동)
  clocking mcb @(posedge clk);
    default input #1step output #1;
    output valid, data, side;
    input  ready;
  endclocking

  // slave 쪽 (TB가 ready 구동)
  clocking scb @(posedge clk);
    default input #1step output #1;
    output ready;
    input  valid, data;
  endclocking

  // 수동 monitor
  clocking moncb @(posedge clk);
    default input #1step;
    input valid, ready, data, side, rst;
  endclocking

  // ---------------- 프로토콜 assertion ----------------
  // valid가 1이 되면 받아들여질 때까지 1을 유지하고 data도 바뀌면 안 됨
  a_hold : assert property (@(posedge clk) disable iff (rst || !chk_en)
             (valid && !ready) |=> (valid && $stable(data)))
    else `uvm_error("VR_SVA", $sformatf("%m: valid dropped or data changed before handshake"))

  a_valid_known : assert property (@(posedge clk) disable iff (rst || !chk_en)
             !$isunknown(valid))
    else `uvm_error("VR_SVA", $sformatf("%m: valid is X/Z"))

  a_ready_known : assert property (@(posedge clk) disable iff (rst || !chk_en)
             !$isunknown(ready))
    else `uvm_error("VR_SVA", $sformatf("%m: ready is X/Z"))

  a_data_known : assert property (@(posedge clk) disable iff (rst || !chk_en)
             valid |-> !$isunknown(data))
    else `uvm_error("VR_SVA", $sformatf("%m: data is X/Z while valid"))

endinterface
