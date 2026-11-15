`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_top : dma_ip_top (기본 adder datapath) + AXI-Lite master + AXI4 slave
// -----------------------------------------------------------------------------
module tb_top;
  import uvm_pkg::*;
  import dma_test_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                       // 100 MHz
  initial begin
    repeat (20) @(posedge clk);
    rst_n <= 1'b1;
  end

  axil_if ctl (clk, rst_n);
  axi4_if mem (clk, rst_n);

  dma_ip_top dut (
    .ap_clk                (clk),
    .ap_rst_n              (rst_n),
    // m00 AXI4 master -> TB 메모리
    .m00_axi_awvalid       (mem.awvalid), .m00_axi_awready (mem.awready),
    .m00_axi_awaddr        (mem.awaddr),  .m00_axi_awid    (mem.awid),
    .m00_axi_awlen         (mem.awlen),   .m00_axi_awsize  (mem.awsize),
    .m00_axi_awburst       (mem.awburst), .m00_axi_awlock  (),
    .m00_axi_awcache       (),            .m00_axi_awprot  (),
    .m00_axi_awqos         (),            .m00_axi_awregion(),
    .m00_axi_awuser        (),
    .m00_axi_wvalid        (mem.wvalid),  .m00_axi_wready  (mem.wready),
    .m00_axi_wdata         (mem.wdata),   .m00_axi_wstrb   (mem.wstrb),
    .m00_axi_wlast         (mem.wlast),   .m00_axi_wid     (),
    .m00_axi_wuser         (),
    .m00_axi_arvalid       (mem.arvalid), .m00_axi_arready (mem.arready),
    .m00_axi_araddr        (mem.araddr),  .m00_axi_arid    (mem.arid),
    .m00_axi_arlen         (mem.arlen),   .m00_axi_arsize  (mem.arsize),
    .m00_axi_arburst       (mem.arburst), .m00_axi_arlock  (),
    .m00_axi_arcache       (),            .m00_axi_arprot  (),
    .m00_axi_arqos         (),            .m00_axi_arregion(),
    .m00_axi_aruser        (),
    .m00_axi_rvalid        (mem.rvalid),  .m00_axi_rready  (mem.rready),
    .m00_axi_rdata         (mem.rdata),   .m00_axi_rlast   (mem.rlast),
    .m00_axi_rid           (mem.rid),     .m00_axi_ruser   (1'b0),
    .m00_axi_rresp         (mem.rresp),
    .m00_axi_bvalid        (mem.bvalid),  .m00_axi_bready  (mem.bready),
    .m00_axi_bresp         (mem.bresp),   .m00_axi_bid     (mem.bid),
    .m00_axi_buser         (1'b0),
    // AXI4-Lite 제어
    .s_axi_control_awvalid (ctl.awvalid), .s_axi_control_awready (ctl.awready),
    .s_axi_control_awaddr  (ctl.awaddr),
    .s_axi_control_wvalid  (ctl.wvalid),  .s_axi_control_wready  (ctl.wready),
    .s_axi_control_wdata   (ctl.wdata),   .s_axi_control_wstrb   (ctl.wstrb),
    .s_axi_control_arvalid (ctl.arvalid), .s_axi_control_arready (ctl.arready),
    .s_axi_control_araddr  (ctl.araddr),
    .s_axi_control_rvalid  (ctl.rvalid),  .s_axi_control_rready  (ctl.rready),
    .s_axi_control_rdata   (ctl.rdata),   .s_axi_control_rresp   (ctl.rresp),
    .s_axi_control_bvalid  (ctl.bvalid),  .s_axi_control_bready  (ctl.bready),
    .s_axi_control_bresp   (ctl.bresp),
    .interrupt             (ctl.interrupt)
  );

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil_agt", "vif", ctl);
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.env.mem_agt",  "vif", mem);
    uvm_top.set_timeout(50ms, 0);
    run_test();
  end
endmodule
