`timescale 1ns/1ps                                  // 시간 단위 1ns, 정밀도 1ps
// 입출력 skid buffer가 붙은 sync_fifo, 파라미터는 dma_ip_top과 같음
// (얕은 버전은 +define+FIFO_DEPTH=4+FIFO_LOG2_DEPTH=2)
`ifndef FIFO_DEPTH                                  // FIFO_DEPTH가 정의되지 않았으면
  `define FIFO_DEPTH 64                             // 기본 깊이 64
`endif                                              // ifndef 끝
`ifndef FIFO_LOG2_DEPTH                             // FIFO_LOG2_DEPTH가 정의되지 않았으면
  `define FIFO_LOG2_DEPTH 7                         // 기본 주소 폭 7
`endif                                              // ifndef 끝
module tb_fifo;                                     // FIFO 테스트벤치 모듈
  import uvm_pkg::*;                                // UVM 라이브러리 import
  import unit_test_pkg::*;                          // unit 테스트 패키지 import
  `define DUT_KIND "fifo"                           // DUT 종류 (그대로 통과 모델)
  `include "tb_unit_common.svh"                     // 클럭, 리셋, 인터페이스, UVM 시작 공통 코드

  sync_fifo #(                                // DUT 인스턴스 (파라미터 시작)
    .FIFO_IN_REG    (1),                            // 입력 skid buffer 사용
    .FIFO_OUT_REG   (1),                            // 출력 skid buffer 사용
    .FIFO_CMD_LENGTH(64),                           // 데이터 폭 64비트
    .FIFO_DEPTH     (`FIFO_DEPTH),                  // 깊이
    .FIFO_LOG2_DEPTH(`FIFO_LOG2_DEPTH)              // 깊이의 log2 + 1
  ) dut (                                           // 포트 연결 시작
    .clk    (clk),                                  // 클럭
    .reset  (rst),                                  // 리셋 (active-high)
    .s_valid(in_if.valid),  .s_ready(in_if.ready),  .s_data(in_if.data),  // 입력 valid / ready / data
    .m_valid(out_if.valid), .m_ready(out_if.ready), .m_data(out_if.data)  // 출력 valid / ready / data
  );                                                // DUT 인스턴스 끝
endmodule                                           // 모듈 끝
