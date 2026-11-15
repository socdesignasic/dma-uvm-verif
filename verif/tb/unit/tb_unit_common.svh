// unit TB top 공통 코드: 클럭, 리셋, vr_if 2개, UVM 시작.
// include하는 모듈이 DUT_KIND(문자열 리터럴)를 정의해야 함.
  logic clk = 1'b0;                                 // 클럭 (0에서 시작)
  logic rst = 1'b1;                                 // active-high 리셋 (처음엔 리셋 상태)
  always #5 clk = ~clk;                       // 100 MHz
  initial begin                                     // 리셋 생성
    repeat (10) @(posedge clk);                     // 10클럭 동안 리셋 유지
    rst <= 1'b0;                                    // 리셋 해제
  end                                               // initial 끝

  vr_if #(64) in_if  (clk, rst);                    // 입력 스트림 인터페이스
  vr_if #(64) out_if (clk, rst);                    // 출력 스트림 인터페이스
  assign out_if.side = '0;                    // 출력 쪽 sideband는 사용 안 함

  initial begin                                     // UVM 시작
    uvm_config_db#(virtual vr_if #(64))::set(null, "uvm_test_top.env.in_agt",  "vif", in_if);  // 입력 agent에 virtual interface 전달
    uvm_config_db#(virtual vr_if #(64))::set(null, "uvm_test_top.env.out_agt", "vif", out_if);  // 출력 agent에 virtual interface 전달
    uvm_config_db#(string)::set(null, "uvm_test_top", "dut_kind", `DUT_KIND);  // 테스트에 DUT 종류 전달
    run_test();                                     // +UVM_TESTNAME으로 지정한 테스트 실행
  end                                               // initial 끝
