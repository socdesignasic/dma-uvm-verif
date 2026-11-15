// dma_reg_bitbash_test : 모든 RW 레지스터에 walking-1/0 쓰기+읽기 (dma_reg_bitbash_seq)
class dma_reg_bitbash_test extends dma_base_test;   // 기본 테스트 상속
  `uvm_component_utils(dma_reg_bitbash_test)        // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual task run_jobs();                          // 작업 대신 레지스터 검사를 실행하도록 override
    dma_reg_bitbash_seq seq = dma_reg_bitbash_seq::type_id::create("seq");  // bit-bash sequence 생성
    env.sb.expect_jobs = 0;                         // DMA 작업이 없으므로 scoreboard의 작업 0개 오류를 끔
    seq.start(env.axil_agt.sqr);                    // AXI4-Lite sequencer에서 실행
  endtask                                           // run_jobs 끝
endclass                                            // 클래스 끝
