`timescale 1ns/1ps
// 입출력 skid buffer가 붙은 sync_fifo, 파라미터는 dma_ip_top과 같음
// (얕은 버전은 +define+FIFO_DEPTH=4+FIFO_LOG2_DEPTH=2)
`ifndef FIFO_DEPTH
  `define FIFO_DEPTH 64
`endif
`ifndef FIFO_LOG2_DEPTH
  `define FIFO_LOG2_DEPTH 7
`endif
module tb_fifo;
  import uvm_pkg::*;
  import unit_test_pkg::*;
  `define DUT_KIND "fifo"
  `include "tb_unit_common.svh"

  sync_fifo #(
    .FIFO_IN_REG    (1),
    .FIFO_OUT_REG   (1),
    .FIFO_CMD_LENGTH(64),
    .FIFO_DEPTH     (`FIFO_DEPTH),
    .FIFO_LOG2_DEPTH(`FIFO_LOG2_DEPTH)
  ) dut (
    .clk    (clk),
    .reset  (rst),
    .s_valid(in_if.valid),  .s_ready(in_if.ready),  .s_data(in_if.data),
    .m_valid(out_if.valid), .m_ready(out_if.ready), .m_data(out_if.data)
  );
endmodule
