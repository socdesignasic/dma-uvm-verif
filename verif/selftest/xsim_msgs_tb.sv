// xsim_msgs_tb.sv - sim.py 판정(judge)이 XSim 자체 메시지를 잡는지 확인하는 자체 시험용 TB.
//
// UVM을 쓰지 않는 작은 모듈입니다. +KIND=<종류>로 메시지 하나를 일부러 냅니다.
//   none      : 아무 메시지도 내지 않음 (PASS여야 함)
//   error     : $error
//   warning   : $warning (판정에 영향 없음)
//   fatal     : $fatal
//   assert    : 동작 블록(else)이 없는 concurrent assertion 실패
//   immediate : 동작 블록이 없는 immediate assertion 실패
//   bind      : bind로 넣은 checker 모듈의 동작 블록 없는 concurrent assertion 실패
//               (top TB의 dma_ap_ctrl_sva처럼 bind로 넣은 검사의 실패도 판정이 잡는지)
// scripts/tests/의 판정 테스트가 이 TB로 얻은 로그 형식을 고정 샘플로 씁니다.
// 다시 확인: python scripts/sim.py run --tb xsim_msgs --plusarg KIND=assert
module xsim_msgs_tb;
  logic clk = 1'b0;                                  // 클록
  always #5 clk = ~clk;                              // 10ns 주기
  logic a = 1'b0;                                    // assertion 대상 신호
  logic b = 1'b0;                                    // bind checker(xsim_msgs_bind_check)의 대상 신호

  // 동작 블록이 없는 concurrent assertion: 실패하면 XSim 기본 메시지만 나옴
  a_never_high : assert property (@(posedge clk) !a);

  string kind;                                       // 낼 메시지 종류
  initial begin
    if (!$value$plusargs("KIND=%s", kind)) kind = "none";  // 기본은 none
    #12;                                             // 첫 클록 에지 뒤
    case (kind)
      "error":     $error("selftest error message");
      "warning":   $warning("selftest warning message");
      "fatal":     $fatal(1, "selftest fatal message");
      "assert":    a = 1'b1;                         // 다음 에지에서 a_never_high 실패
      "immediate": assert (a);                       // a = 0이므로 실패
      "bind":      b = 1'b1;                         // 다음 에지에서 bind checker의 a_bind_never_high 실패
      default:     ;                                 // none
    endcase
    #20 $finish;                                     // 끝
  end
endmodule

// bind로 넣는 작은 checker: 동작 블록(else)이 없는 concurrent assertion 하나
module xsim_msgs_bind_check (input logic clk, input logic sig);
  a_bind_never_high : assert property (@(posedge clk) !sig);
endmodule

// 파일 끝 $unit의 bind (top TB의 dma_ap_ctrl_sva.sv와 같은 방식)
bind xsim_msgs_tb xsim_msgs_bind_check u_bind_check (.clk(clk), .sig(b));
