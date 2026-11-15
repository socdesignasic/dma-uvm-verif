`timescale 1ns/1ps                                  // 시간 단위 1ns, 정밀도 1ps
// -----------------------------------------------------------------------------
// tb_top : dma_ip_top (기본 adder datapath) + AXI-Lite master + AXI4 slave
// -----------------------------------------------------------------------------
module tb_top;                                      // top 테스트벤치 모듈
  import uvm_pkg::*;                                // UVM 라이브러리 import (run_test, config_db)
  import dma_test_pkg::*;                           // top 테스트 패키지 import

  logic clk   = 1'b0;                               // 클럭 (0에서 시작)
  logic rst_n = 1'b0;                               // active-low 리셋 (처음엔 리셋 상태)
  always #5 clk = ~clk;                       // 100 MHz
  initial begin                                     // 리셋 생성
    repeat (20) @(posedge clk);                     // 20클럭 동안 리셋 유지
    rst_n <= 1'b1;                                  // 리셋 해제
  end                                               // initial 끝

  axil_if ctl (clk, rst_n);                         // AXI4-Lite 제어 인터페이스
  axi4_if mem (clk, rst_n);                         // AXI4 메모리 인터페이스

  dma_ip_top dut (                            // DUT 인스턴스
    .ap_clk                (clk),                   // 클럭
    .ap_rst_n              (rst_n),                 // 리셋 (active-low)
    // m00 AXI4 master -> TB 메모리
    .m00_axi_awvalid       (mem.awvalid), .m00_axi_awready (mem.awready),  // AW valid / ready
    .m00_axi_awaddr        (mem.awaddr),  .m00_axi_awid    (mem.awid),  // AW 주소 / ID
    .m00_axi_awlen         (mem.awlen),   .m00_axi_awsize  (mem.awsize),  // AW 길이 / size
    .m00_axi_awburst       (mem.awburst), .m00_axi_awlock  (),  // AW burst / lock (사용 안 함)
    .m00_axi_awcache       (),            .m00_axi_awprot  (),  // AW cache / prot (사용 안 함)
    .m00_axi_awqos         (),            .m00_axi_awregion(),  // AW qos / region (사용 안 함)
    .m00_axi_awuser        (),                      // AW user (사용 안 함)
    .m00_axi_wvalid        (mem.wvalid),  .m00_axi_wready  (mem.wready),  // W valid / ready
    .m00_axi_wdata         (mem.wdata),   .m00_axi_wstrb   (mem.wstrb),  // W 데이터 / strobe
    .m00_axi_wlast         (mem.wlast),   .m00_axi_wid     (),  // W last / id (사용 안 함)
    .m00_axi_wuser         (),                      // W user (사용 안 함)
    .m00_axi_arvalid       (mem.arvalid), .m00_axi_arready (mem.arready),  // AR valid / ready
    .m00_axi_araddr        (mem.araddr),  .m00_axi_arid    (mem.arid),  // AR 주소 / ID
    .m00_axi_arlen         (mem.arlen),   .m00_axi_arsize  (mem.arsize),  // AR 길이 / size
    .m00_axi_arburst       (mem.arburst), .m00_axi_arlock  (),  // AR burst / lock (사용 안 함)
    .m00_axi_arcache       (),            .m00_axi_arprot  (),  // AR cache / prot (사용 안 함)
    .m00_axi_arqos         (),            .m00_axi_arregion(),  // AR qos / region (사용 안 함)
    .m00_axi_aruser        (),                      // AR user (사용 안 함)
    .m00_axi_rvalid        (mem.rvalid),  .m00_axi_rready  (mem.rready),  // R valid / ready
    .m00_axi_rdata         (mem.rdata),   .m00_axi_rlast   (mem.rlast),  // R 데이터 / last
    .m00_axi_rid           (mem.rid),     .m00_axi_ruser   (1'b0),  // R ID / user (0으로 고정)
    .m00_axi_rresp         (mem.rresp),             // R 응답
    .m00_axi_bvalid        (mem.bvalid),  .m00_axi_bready  (mem.bready),  // B valid / ready
    .m00_axi_bresp         (mem.bresp),   .m00_axi_bid     (mem.bid),  // B 응답 / ID
    .m00_axi_buser         (1'b0),                  // B user (0으로 고정)
    // AXI4-Lite 제어
    .s_axi_control_awvalid (ctl.awvalid), .s_axi_control_awready (ctl.awready),  // AW valid / ready
    .s_axi_control_awaddr  (ctl.awaddr),            // AW 주소
    .s_axi_control_wvalid  (ctl.wvalid),  .s_axi_control_wready  (ctl.wready),  // W valid / ready
    .s_axi_control_wdata   (ctl.wdata),   .s_axi_control_wstrb   (ctl.wstrb),  // W 데이터 / strobe
    .s_axi_control_arvalid (ctl.arvalid), .s_axi_control_arready (ctl.arready),  // AR valid / ready
    .s_axi_control_araddr  (ctl.araddr),            // AR 주소
    .s_axi_control_rvalid  (ctl.rvalid),  .s_axi_control_rready  (ctl.rready),  // R valid / ready
    .s_axi_control_rdata   (ctl.rdata),   .s_axi_control_rresp   (ctl.rresp),  // R 데이터 / 응답
    .s_axi_control_bvalid  (ctl.bvalid),  .s_axi_control_bready  (ctl.bready),  // B valid / ready
    .s_axi_control_bresp   (ctl.bresp),             // B 응답
    .interrupt             (ctl.interrupt)          // 인터럽트 출력
  );                                                // DUT 인스턴스 끝

  initial begin                                     // UVM 시작
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil_agt", "vif", ctl);  // AXI4-Lite agent에 virtual interface 전달
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.env.mem_agt",  "vif", mem);  // 메모리 agent에 virtual interface 전달
    uvm_top.set_timeout(50ms, 0);                   // 전체 시간 제한 50ms (넘으면 중단)
    run_test();                                     // +UVM_TESTNAME으로 지정한 테스트 실행
  end                                               // initial 끝
endmodule                                           // 모듈 끝
