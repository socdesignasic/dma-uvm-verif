`timescale 1ns/1ps
// axis_adder, 64-bit data. ctrl_constant is driven per beat from in_if.side.
//   default        : 2 x 32-bit lanes (module default)
//   +define+ADDER_BW=8 : 8 x 8-bit lanes, as instantiated in dma_ip_top
`ifndef ADDER_BW
  `define ADDER_BW 32
`endif
module tb_adder;
  import uvm_pkg::*;
  import unit_test_pkg::*;
  `define DUT_KIND "adder"
  `include "tb_unit_common.svh"

  initial uvm_config_db#(int unsigned)::set(null, "uvm_test_top", "lane_bw", `ADDER_BW);

  axis_adder #(
    .C_AXIS_TDATA_WIDTH(64),
    .C_ADDER_BIT_WIDTH (`ADDER_BW),
    .C_NUM_CLOCKS      (1)
  ) dut (
    .ctrl_constant (in_if.side[`ADDER_BW-1:0]),
    .s_axis_aclk   (clk),
    .s_axis_areset (rst),
    .s_axis_tvalid (in_if.valid),
    .s_axis_tready (in_if.ready),
    .s_axis_tdata  (in_if.data),
    .s_axis_tkeep  ('0),
    .s_axis_tstrb  ('1),
    .s_axis_tlast  (1'b0),
    .s_axis_tid    ('0),
    .s_axis_tdest  ('0),
    .s_axis_tuser  ('0),
    .m_axis_aclk   (clk),
    .m_axis_tvalid (out_if.valid),
    .m_axis_tready (out_if.ready),
    .m_axis_tdata  (out_if.data),
    .m_axis_tkeep  (), .m_axis_tstrb(), .m_axis_tlast(),
    .m_axis_tid    (), .m_axis_tdest(), .m_axis_tuser()
  );
endmodule
