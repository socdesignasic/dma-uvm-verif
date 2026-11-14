`timescale 1ns/1ps
module tb_skid;
  import uvm_pkg::*;
  import unit_test_pkg::*;
  `define DUT_KIND "skid"
  `include "tb_unit_common.svh"

  skid_buffer #(.DATA_WIDTH(64)) dut (
    .clk    (clk),
    .rst    (rst),
    .s_valid(in_if.valid),  .s_ready(in_if.ready),  .s_data(in_if.data),
    .m_valid(out_if.valid), .m_ready(out_if.ready), .m_data(out_if.data)
  );
endmodule
