// -----------------------------------------------------------------------------
// axil_if : AXI4-Lite (주소 12비트, 데이터 32비트) + DUT 인터럽트 신호
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"

interface axil_if (input logic clk, input logic rst_n);
  import uvm_pkg::*;

  logic        awvalid, awready;  logic [11:0] awaddr;
  logic        wvalid,  wready;   logic [31:0] wdata;  logic [3:0] wstrb;
  logic        bvalid,  bready;   logic [1:0]  bresp;
  logic        arvalid, arready;  logic [11:0] araddr;
  logic        rvalid,  rready;   logic [31:0] rdata;  logic [1:0] rresp;
  logic        interrupt;

  clocking cb @(posedge clk);
    default input #1step output #1;
    output awvalid, awaddr, wvalid, wdata, wstrb, bready, arvalid, araddr, rready;
    input  awready, wready, bvalid, bresp, arready, rvalid, rdata, rresp, interrupt;
  endclocking

  // slave(DUT) 쪽 프로토콜 검사
  a_b_hold : assert property (@(posedge clk) disable iff (!rst_n)
               (bvalid && !bready) |=> bvalid)
    else `uvm_error("AXIL_SVA", "BVALID dropped before BREADY")
  a_r_hold : assert property (@(posedge clk) disable iff (!rst_n)
               (rvalid && !rready) |=> (rvalid && $stable(rdata)))
    else `uvm_error("AXIL_SVA", "RVALID dropped / RDATA changed before RREADY")
  a_irq_known : assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(interrupt))
    else `uvm_error("AXIL_SVA", "interrupt is X/Z")
endinterface
