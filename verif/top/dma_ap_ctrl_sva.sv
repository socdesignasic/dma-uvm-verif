`timescale 1ns/1ps                                  // 시간 단위 1ns, 정밀도 1ps
// -----------------------------------------------------------------------------
// dma_ap_ctrl_sva : dma_ip_top 안쪽 ap_ctrl_hs 신호(ap_start, ap_done, ap_idle, ap_ready) 검사
//   이 파일 끝의 bind로 dma_ip_top 안에 u_ap_ctrl_sva로 들어감 (RTL 파일은 고치지 않음).
//   신호: ap_start = control의 int_ap_start (control.v:281), ap_idle/ap_done/ap_ready = WDMA 상태
//   (wdma.v:339-341, wrapper.v:160-162). areset = ~ap_rst_n을 한 번 레지스터한 것 (top.v:140-142).
//   리셋 중과 리셋 해제 뒤 areset이 남은 한 사이클은 검사하지 않음 (disable iff).
//   실패하면 UVM_ERROR [APCTRL_SVA] "<라벨>: ..." (sim.py 판정과 check_inventory가 이 태그를 셈).
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"                           // `uvm_error 매크로를 쓰기 위해 포함

module dma_ap_ctrl_sva (                            // ap_ctrl_hs 검사 모듈 (bind 대상: dma_ip_top)
  input logic clk,                                  // ap_clk
  input logic rst_n,                                // ap_rst_n (active-low)
  input logic areset,                               // top의 레지스터된 리셋 (control, adder, FIFO 리셋)
  input logic ap_start,                             // control -> wrapper (level, COH)
  input logic ap_done,                              // WDMA S_DONE
  input logic ap_idle,                              // WDMA S_IDLE
  input logic ap_ready                              // WDMA S_PRE
);
  import uvm_pkg::*;                                // SVA에서 UVM 보고 함수를 쓰기 위해 import

  // ap_start는 ap_ready를 받을 때까지 내려가면 안 됨 (control.v:308-311: ap_ready에서만 지움)
  a_ap_start_hold : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      (ap_start && !ap_ready) |=> ap_start)
    else `uvm_error("APCTRL_SVA", "a_ap_start_hold: ap_start dropped before ap_ready")

  // ap_ready는 받아들일 start가 있을 때만 나옴
  a_ap_ready_with_start : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      ap_ready |-> ap_start)
    else `uvm_error("APCTRL_SVA", "a_ap_ready_with_start: ap_ready=1 while ap_start=0")

  // ap_ready는 한 사이클 펄스 (wdma.v:327 S_PRE -> S_RUN)
  a_ap_ready_pulse : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      ap_ready |=> !ap_ready)
    else `uvm_error("APCTRL_SVA", "a_ap_ready_pulse: ap_ready high for more than one cycle")

  // ap_done은 한 사이클 펄스 (wdma.v:330 S_DONE -> S_IDLE)
  a_ap_done_pulse : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      ap_done |=> !ap_done)
    else `uvm_error("APCTRL_SVA", "a_ap_done_pulse: ap_done high for more than one cycle")

  // idle과 ready/done은 동시에 나오지 않음 (상태 배타)
  a_ap_idle_excl : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      ap_idle |-> (!ap_ready && !ap_done))
    else `uvm_error("APCTRL_SVA", "a_ap_idle_excl: ap_idle=1 together with ap_ready or ap_done")

  // idle인데 start가 있으면 곧 idle을 떠나야 함 (start가 새로 오든, start가 남은 채 idle로 돌아오든)
  //   RTL 지연 (전방 샘플 기준, E1 = ap_start && ap_idle이 처음 1로 샘플된 에지):
  //     E1: wrapper ap_start_pulse=1 -> r_ap_start_wdma <= 1 (wrapper.v:138, 153-154)
  //     E2: WDMA is_run=1 (r_ap_start_wdma && !tick_ff, wdma.v:310) -> c_state <= S_PRE (wdma.v:325-326)
  //     E3: ap_idle=0으로 샘플됨 -> E1 + 2
  //   상한 2 = 이 RTL 지연 그대로 (여유 0사이클). 하한 1 = wrapper 레지스터 없이 level로 고친 RTL (E1 + 1).
  a_ap_idle_leave : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      $rose(ap_start && ap_idle) |-> ##[1:2] !ap_idle)
    else `uvm_error("APCTRL_SVA", "a_ap_idle_leave: ap_start=1 while idle, but ap_idle did not fall within 2 cycles")

  // DUT는 스스로 시작하지 않음: idle이 내려가기 직전 사이클에 ap_start가 있어야 함
  a_ap_idle_fall_start : assert property (@(posedge clk) disable iff (!rst_n || areset)
                      $fell(ap_idle) |-> $past(ap_start))
    else `uvm_error("APCTRL_SVA", "a_ap_idle_fall_start: ap_idle fell without ap_start in the previous cycle")
endmodule                                           // 모듈 끝

// dma_ip_top의 모든 인스턴스에 검사 모듈을 넣음 (신호 이름: top.v:119-123)
bind dma_ip_top dma_ap_ctrl_sva u_ap_ctrl_sva (.clk(ap_clk), .rst_n(ap_rst_n), .areset(areset),
  .ap_start(ap_start), .ap_done(ap_done), .ap_idle(ap_idle), .ap_ready(ap_ready));
