`timescale 1ns/1ps                                  // 시간 단위 1ns, 정밀도 1ps
// axis_adder, 데이터 64비트. ctrl_constant는 beat마다 in_if.side로 구동.
//   기본값         : 32비트 lane 2개 (모듈 기본값)
//   +define+ADDER_BW=8 : 8비트 lane 8개, dma_ip_top과 같은 설정
`ifndef ADDER_BW                                    // ADDER_BW가 정의되지 않았으면
  `define ADDER_BW 32                               // 기본 lane 폭 32
`endif                                              // ifndef 끝
module tb_adder;                                    // adder 테스트벤치 모듈
  import uvm_pkg::*;                                // UVM 라이브러리 import
  import unit_test_pkg::*;                          // unit 테스트 패키지 import
  `define DUT_KIND "adder"                          // DUT 종류 (scoreboard 모델 선택용)
  `include "tb_unit_common.svh"                     // 클럭, 리셋, 인터페이스, UVM 시작 공통 코드

  initial uvm_config_db#(int unsigned)::set(null, "uvm_test_top", "lane_bw", `ADDER_BW);  // 테스트에 lane 폭 전달

  axis_adder #(                               // DUT 인스턴스 (파라미터 시작)
    .C_AXIS_TDATA_WIDTH(64),                        // 데이터 폭 64비트
    .C_ADDER_BIT_WIDTH (`ADDER_BW),                 // lane 폭
    .C_NUM_CLOCKS      (1)                          // 파이프라인 1클럭
  ) dut (                                           // 포트 연결 시작
    .ctrl_constant (in_if.side[`ADDER_BW-1:0]),     // 더할 값 = 입력 sideband의 하위 lane 폭 비트
    .s_axis_aclk   (clk),                           // 입력 클럭
    .s_axis_areset (rst),                           // 입력 리셋 (active-high)
    .s_axis_tvalid (in_if.valid),                   // 입력 valid
    .s_axis_tready (in_if.ready),                   // 입력 ready
    .s_axis_tdata  (in_if.data),                    // 입력 데이터
    .s_axis_tkeep  ('0),                            // tkeep (사용 안 함)
    .s_axis_tstrb  ('1),                            // tstrb (전부 1)
    .s_axis_tlast  (1'b0),                          // tlast (사용 안 함)
    .s_axis_tid    ('0),                            // tid (사용 안 함)
    .s_axis_tdest  ('0),                            // tdest (사용 안 함)
    .s_axis_tuser  ('0),                            // tuser (사용 안 함)
    .m_axis_aclk   (clk),                           // 출력 클럭
    .m_axis_tvalid (out_if.valid),                  // 출력 valid
    .m_axis_tready (out_if.ready),                  // 출력 ready
    .m_axis_tdata  (out_if.data),                   // 출력 데이터
    .m_axis_tkeep  (), .m_axis_tstrb(), .m_axis_tlast(),  // 출력 keep/strb/last (사용 안 함)
    .m_axis_tid    (), .m_axis_tdest(), .m_axis_tuser()  // 출력 id/dest/user (사용 안 함)
  );                                                // DUT 인스턴스 끝
endmodule                                           // 모듈 끝
