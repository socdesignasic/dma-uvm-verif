// dma_reg_bitbash_test : RW 레지스터 8개에 0 배경과 1 배경으로 비트마다 쓰기+읽기 (dma_reg_bitbash_vseq, RAL 내장 bit-bash)
//   32비트 비교는 dma_predictor (REG_BITBASH). AP_CTRL과 ISR에는 쓰지 않음
class dma_reg_bitbash_test extends dma_base_test;   // 기본 테스트 상속
  `uvm_component_utils(dma_reg_bitbash_test)        // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual task run_jobs();                          // 작업 대신 bit-bash를 실행하도록 override
    dma_reg_bitbash_vseq seq = dma_reg_bitbash_vseq::type_id::create("bitbash_vseq");  // bit-bash virtual sequence 생성
    env.sb.expect_jobs = 0;                         // DMA 작업이 없으므로 scoreboard의 작업 0개 오류를 끔
    seq.start(env.vsqr);                            // virtual sequencer에서 실행 (리셋 직후, 1회차 전제)
  endtask                                           // run_jobs 끝
endclass                                            // 클래스 끝
