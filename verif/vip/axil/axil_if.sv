// -----------------------------------------------------------------------------
// axil_if : AXI4-Lite (주소 12비트, 데이터 32비트) + DUT 인터럽트 신호
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"                           // `uvm_error 매크로를 쓰기 위해 포함

interface axil_if (input logic clk, input logic rst_n);  // AXI4-Lite 인터페이스 (클럭, active-low 리셋 입력)
  import uvm_pkg::*;                                // SVA에서 UVM 보고 함수를 쓰기 위해 import

  logic        awvalid, awready;  logic [11:0] awaddr;  // AW 채널: valid, ready, 주소
  logic        wvalid,  wready;   logic [31:0] wdata;  logic [3:0] wstrb;  // W 채널: valid, ready, 데이터, strobe
  logic        bvalid,  bready;   logic [1:0]  bresp;  // B 채널: valid, ready, 응답
  logic        arvalid, arready;  logic [11:0] araddr;  // AR 채널: valid, ready, 주소
  logic        rvalid,  rready;   logic [31:0] rdata;  logic [1:0] rresp;  // R 채널: valid, ready, 데이터, 응답
  logic        interrupt;                           // DUT 인터럽트 출력

  clocking cb @(posedge clk);                       // 클럭 상승 에지 기준 clocking block
    default input #1step output #1;                 // 입력은 에지 직전 값, 출력은 에지 1 time unit 뒤
    output awvalid, awaddr, wvalid, wdata, wstrb, bready, arvalid, araddr, rready;  // TB(master)가 구동하는 신호
    input  awready, wready, bvalid, bresp, arready, rvalid, rdata, rresp, interrupt;  // DUT(slave)가 구동하는 신호
  endclocking                                       // clocking block 끝

  // 수동 monitor용 clocking block (모든 채널의 handshake 양쪽 신호와 payload를 샘플링)
  clocking moncb @(posedge clk);                    // monitor 전용 clocking block
    default input #1step;                           // 입력만 있음 (에지 직전 값 샘플)
    input awvalid, awready, awaddr,                 // AW handshake와 주소
          wvalid, wready, wdata, wstrb,             // W handshake와 데이터, strobe
          bvalid, bready, bresp,                    // B handshake와 응답
          arvalid, arready, araddr,                 // AR handshake와 주소
          rvalid, rready, rdata, rresp,             // R handshake와 데이터, 응답
          interrupt;                                // DUT 인터럽트 출력
  endclocking                                       // clocking block 끝

  // slave(DUT) 쪽 프로토콜 검사
  a_b_hold : assert property (@(posedge clk) disable iff (!rst_n)  // B 채널 유지 검사 (리셋 중엔 끔)
               (bvalid && !bready) |=> bvalid)      // BVALID가 받아들여지기 전에 내려가면 안 됨
    else `uvm_error("AXIL_SVA", "BVALID dropped before BREADY")  // 위반 시 UVM_ERROR
  a_r_hold : assert property (@(posedge clk) disable iff (!rst_n)  // R 채널 유지 검사
               (rvalid && !rready) |=> (rvalid && $stable(rdata)))  // RVALID 유지, RDATA 고정
    else `uvm_error("AXIL_SVA", "RVALID dropped / RDATA changed before RREADY")  // 위반 시 UVM_ERROR
  a_irq_known : assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(interrupt))  // 인터럽트에 X/Z가 없어야 함
    else `uvm_error("AXIL_SVA", "interrupt is X/Z")  // 위반 시 UVM_ERROR
endinterface                                        // 인터페이스 끝
