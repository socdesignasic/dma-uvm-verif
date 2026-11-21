// -----------------------------------------------------------------------------
// axi4_if : AXI4 memory-mapped (주소 32비트, 데이터 64비트, ID 1비트)
// TB가 SLAVE(메모리 모델)이고, DUT(dma_ip m00)가 master입니다.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"                           // `uvm_error 매크로를 쓰기 위해 포함

interface axi4_if (input logic clk, input logic rst_n);  // AXI4 인터페이스 (클럭, active-low 리셋 입력)
  import uvm_pkg::*;                                // SVA에서 UVM 보고 함수를 쓰기 위해 import

  // AW
  logic        awvalid, awready;                    // AW 채널 valid / ready
  logic [31:0] awaddr;  logic [7:0] awlen;  logic [2:0] awsize; logic [1:0] awburst;  // AW 주소, 길이, size, burst 종류
  logic [0:0]  awid;                                // AW ID
  // W
  logic        wvalid, wready;                      // W 채널 valid / ready
  logic [63:0] wdata;   logic [7:0] wstrb;  logic wlast;  // W 데이터, 바이트 strobe, 마지막 beat 표시
  // B
  logic        bvalid, bready;                      // B 채널 valid / ready
  logic [1:0]  bresp;   logic [0:0] bid;            // B 응답 코드, ID
  // AR
  logic        arvalid, arready;                    // AR 채널 valid / ready
  logic [31:0] araddr;  logic [7:0] arlen;  logic [2:0] arsize; logic [1:0] arburst;  // AR 주소, 길이, size, burst 종류
  logic [0:0]  arid;                                // AR ID
  // R
  logic        rvalid, rready;                      // R 채널 valid / ready
  logic [63:0] rdata;   logic rlast; logic [1:0] rresp; logic [0:0] rid;  // R 데이터, 마지막 beat, 응답 코드, ID

  // slave 쪽 clocking block (TB가 AW/W/AR의 *ready와 B/R 채널을 구동)
  clocking cb @(posedge clk);                       // 클럭 상승 에지 기준 clocking block
    default input #1step output #1;                 // 입력은 에지 직전 값, 출력은 에지 1 time unit 뒤
    output awready, wready, bvalid, bresp, bid, arready, rvalid, rdata, rlast, rresp, rid;  // TB(slave)가 구동하는 신호
    input  awvalid, awaddr, awlen, awsize, awburst, awid,  // DUT(master)가 구동하는 AW 신호를 입력으로 읽음
           wvalid, wdata, wstrb, wlast, bready,     // W 신호와 B 채널 bready
           arvalid, araddr, arlen, arsize, arburst, arid, rready;  // AR 신호와 R 채널 rready
  endclocking                                       // clocking block 끝

  // 수동 monitor용 clocking block (모든 handshake의 양쪽 신호를 샘플링)
  clocking moncb @(posedge clk);                    // monitor 전용 clocking block
    default input #1step;                           // 입력만 있음 (에지 직전 값 샘플)
    input arvalid, arready, araddr, arlen, arsize, arburst,  // AR handshake와 payload
          awvalid, awready, awaddr, awlen, awsize, awburst,  // AW handshake와 payload
          wvalid, wready, wdata, wstrb, wlast,      // W handshake와 payload
          bvalid, bready, bresp, bid,               // B handshake와 응답
          rvalid, rready, rlast;                    // R handshake (beat 수를 세는 쪽용)
  endclocking                                       // clocking block 끝

  // ---------------- master(DUT) 쪽 프로토콜 검사 ----------------
  // AXI_HOLD: VALID가 1이고 READY가 0이면 다음 사이클에도 VALID 유지, payload 고정이어야 함
  `define AXI_HOLD(name, v, r, payload) \
    name : assert property (@(posedge clk) disable iff (!rst_n) \
             (v && !r) |=> (v && $stable(payload))) \
      else `uvm_error("AXI_SVA", `"name: VALID dropped or payload changed before READY`")

  `AXI_HOLD(a_ar_hold, arvalid, arready, {araddr, arlen, arsize, arburst})  // AR 채널: 주소/길이/size/burst 유지 검사
  `AXI_HOLD(a_aw_hold, awvalid, awready, {awaddr, awlen, awsize, awburst})  // AW 채널: 주소/길이/size/burst 유지 검사
  `AXI_HOLD(a_w_hold,  wvalid,  wready,  {wdata, wstrb, wlast})  // W 채널: 데이터/strobe/last 유지 검사

  a_valid_known : assert property (@(posedge clk) disable iff (!rst_n)  // 리셋이 아닐 때 매 사이클 검사
                    !$isunknown({arvalid, awvalid, wvalid, rready, bready}))  // master가 내는 VALID/READY에 X/Z가 없어야 함
    else `uvm_error("AXI_SVA", "master VALID/READY is X/Z")  // 위반 시 UVM_ERROR로 보고
endinterface                                        // 인터페이스 끝
