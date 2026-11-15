`timescale 1ns/1ps
// axis_adder, 데이터 64비트. ctrl_constant는 beat마다 in_if.side로 구동.
//   기본값         : 32비트 lane 2개 (모듈 기본값)
//   +define+ADDER_BW=8 : 8비트 lane 8개, dma_ip_top과 같은 설정
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
