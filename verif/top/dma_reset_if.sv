// -----------------------------------------------------------------------------
// dma_reset_if : DUT와 TB 인터페이스(axil_if, axi4_if)가 함께 쓰는 active-low 리셋 (전원 리셋 + 테스트 중간 리셋)
//   rst_n은 클럭 상승 에지에서 NBA로만 바뀜. DUT는 에지마다 바뀌기 전 값을 봄
//   power_on(n) : tb_dma가 0시에 부름. 처음부터 0, n번째 상승 에지에서 1 (plain @(posedge clk), 예전 tb_dma와 같음)
//   pulse(n)    : dma_reset_vseq가 클럭 에지(@(moncb) 뒤)에서 부름. 그 에지 E에서 0, n 에지 뒤 R = E + n클럭에서 1
//                 -> DUT는 E+1클럭 ~ R 에지, n 에지 동안 리셋을 봄
//   TB 쪽은 @(cb) 바로 뒤 vif.rst_n을 읽어 리셋 에지를 판단함. XSim은 @(cb) process를 plain @(posedge) process의 NBA 뒤에
//   깨우므로 해제 에지 R은 이미 1로 읽힘 (전원 리셋 해제 때와 같음, 2026-11-21 VCD로 확인). 그래서 TB는 n-1 에지를 리셋으로 봄
//   -> dma_reset_vseq는 n >= 2만 허용
// -----------------------------------------------------------------------------
interface dma_reset_if (input logic clk);           // 리셋 인터페이스 (클럭 입력)
  logic rst_n = 1'b0;                               // active-low 리셋 (처음엔 리셋 상태)

  task automatic power_on(int unsigned n);          // 전원 리셋: n 클럭 동안 유지
    repeat (n) @(posedge clk);                      // n번째 상승 에지까지 대기
    rst_n <= 1'b1;                                  // 리셋 해제
  endtask                                           // power_on 끝

  // 부른 시각의 에지는 세지 않음: 어떤 이벤트로 깨어나 불렀든(이 clk 포트의 같은 시각 에지가 아직 안 왔어도) 정확히 n 에지
  task automatic pulse(int unsigned n);             // 테스트 중간 리셋: 클럭 상승 에지에서 부름 (n >= 1)
    time t0 = $time;                                // 부른 시각
    rst_n <= 1'b0;                                  // 이 에지에서 리셋 (DUT는 다음 에지부터 봄)
    repeat (n)                                      // n 에지 동안 유지
      do @(posedge clk); while ($time == t0);       // 부른 시각과 같은 에지는 건너뜀
    rst_n <= 1'b1;                                  // 리셋 해제
  endtask                                           // pulse 끝
endinterface                                        // 인터페이스 끝
