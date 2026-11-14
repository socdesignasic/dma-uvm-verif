// -----------------------------------------------------------------------------
// vr_if : generic valid/ready stream interface (64-bit data + 32-bit sideband)
//   side : sideband sampled together with each beat
//          (axis_adder: ctrl_constant; ignored by FIFO / skid buffer)
// Protocol checks (SVA) report through UVM so sim.py counts them as UVM_ERROR.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"

interface vr_if #(parameter int DW = 64) (input logic clk, input logic rst);
  import uvm_pkg::*;

  logic          valid;
  logic          ready;
  logic [DW-1:0] data;
  logic [31:0]   side;

  bit chk_en = 1'b1;   // protocol checks on/off (e.g. for error-injection tests)

  // master side (TB drives valid/data/side)
  clocking mcb @(posedge clk);
    default input #1step output #1;
    output valid, data, side;
    input  ready;
  endclocking

  // slave side (TB drives ready)
  clocking scb @(posedge clk);
    default input #1step output #1;
    output ready;
    input  valid, data;
  endclocking

  // passive monitor
  clocking moncb @(posedge clk);
    default input #1step;
    input valid, ready, data, side, rst;
  endclocking

  // ---------------- protocol assertions ----------------
  // Once valid is high it must stay high with stable data until accepted.
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
