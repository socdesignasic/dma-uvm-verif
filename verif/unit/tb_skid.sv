`timescale 1ns/1ps                                  // 시간 단위 1ns, 정밀도 1ps
module tb_skid;                                     // skid buffer 테스트벤치 모듈
  import uvm_pkg::*;                                // UVM 라이브러리 import
  import unit_test_pkg::*;                          // unit 테스트 패키지 import
  `define DUT_KIND "skid"                           // DUT 종류 (그대로 통과 모델)
  `include "tb_unit_common.svh"                     // 클럭, 리셋, 인터페이스, UVM 시작 공통 코드

  skid_buffer #(.DATA_WIDTH(64)) dut (        // DUT 인스턴스 (데이터 폭 64비트)
    .clk    (clk),                                  // 클럭
    .rst    (rst),                                  // 리셋 (active-high)
    .s_valid(in_if.valid),  .s_ready(in_if.ready),  .s_data(in_if.data),  // 입력 valid / ready / data
    .m_valid(out_if.valid), .m_ready(out_if.ready), .m_data(out_if.data)  // 출력 valid / ready / data
  );                                                // DUT 인스턴스 끝
endmodule                                           // 모듈 끝
