// dma_reg_reset_test : 리셋 직후 레지스터 10개를 모두 읽음 (RAL 내장 uvm_reg_hw_reset_seq, frontdoor)
//   32비트 리셋 값 비교는 dma_predictor (REG_RESET). 내장 sequence도 mirror(리셋 값)와 비교함
class dma_reg_reset_test extends dma_base_test;     // 기본 테스트 상속
  `uvm_component_utils(dma_reg_reset_test)          // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual task run_jobs();                          // 작업 대신 레지스터 읽기를 실행하도록 override
    uvm_reg_hw_reset_seq seq = uvm_reg_hw_reset_seq::type_id::create("hw_reset_seq");  // 내장 리셋 값 sequence 생성
    env.sb.expect_jobs = 0;                         // DMA 작업이 없으므로 scoreboard의 작업 0개 오류를 끔
    seq.model = env.regmodel;                       // 대상 블록
    seq.start(null);                                // frontdoor 접근은 map의 sequencer(AXI4-Lite)로 감
  endtask                                           // run_jobs 끝
endclass                                            // 클래스 끝
