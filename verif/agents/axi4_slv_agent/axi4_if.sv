// -----------------------------------------------------------------------------
// axi4_if : AXI4 memory-mapped (32-bit addr, 64-bit data, 1-bit ID)
// The TB is the SLAVE (memory model); the DUT (dma_ip m00) is the master.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"

interface axi4_if (input logic clk, input logic rst_n);
  import uvm_pkg::*;

  // AW
  logic        awvalid, awready;
  logic [31:0] awaddr;  logic [7:0] awlen;  logic [2:0] awsize; logic [1:0] awburst;
  logic [0:0]  awid;
  // W
  logic        wvalid, wready;
  logic [63:0] wdata;   logic [7:0] wstrb;  logic wlast;
  // B
  logic        bvalid, bready;
  logic [1:0]  bresp;   logic [0:0] bid;
  // AR
  logic        arvalid, arready;
  logic [31:0] araddr;  logic [7:0] arlen;  logic [2:0] arsize; logic [1:0] arburst;
  logic [0:0]  arid;
  // R
  logic        rvalid, rready;
  logic [63:0] rdata;   logic rlast; logic [1:0] rresp; logic [0:0] rid;

  // slave-side clocking block (TB drives *ready on AW/W/AR and the B/R channels)
  clocking cb @(posedge clk);
    default input #1step output #1;
    output awready, wready, bvalid, bresp, bid, arready, rvalid, rdata, rlast, rresp, rid;
    input  awvalid, awaddr, awlen, awsize, awburst, awid,
           wvalid, wdata, wstrb, wlast, bready,
           arvalid, araddr, arlen, arsize, arburst, arid, rready;
  endclocking

  // passive monitor clocking block (samples both sides of every handshake)
  clocking moncb @(posedge clk);
    default input #1step;
    input arvalid, arready, araddr, arlen, arsize, arburst,
          awvalid, awready, awaddr, awlen, awsize, awburst;
  endclocking

  // ---------------- master-side (DUT) protocol checks ----------------
  `define AXI_HOLD(name, v, r, payload) \
    name : assert property (@(posedge clk) disable iff (!rst_n) \
             (v && !r) |=> (v && $stable(payload))) \
      else `uvm_error("AXI_SVA", `"name: VALID dropped or payload changed before READY`")

  `AXI_HOLD(a_ar_hold, arvalid, arready, {araddr, arlen, arsize, arburst})
  `AXI_HOLD(a_aw_hold, awvalid, awready, {awaddr, awlen, awsize, awburst})
  `AXI_HOLD(a_w_hold,  wvalid,  wready,  {wdata, wstrb, wlast})

  a_valid_known : assert property (@(posedge clk) disable iff (!rst_n)
                    !$isunknown({arvalid, awvalid, wvalid, rready, bready}))
    else `uvm_error("AXI_SVA", "master VALID/READY is X/Z")
endinterface
