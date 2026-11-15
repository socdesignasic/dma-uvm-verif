// dma_small_test : 1..20 beat 작업 30개: 덜 찬 burst, beat 하나짜리
class dma_small_test extends dma_base_test;         // 기본 테스트 상속
  `uvm_component_utils(dma_small_test)              // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 30; min_beats = 1; max_beats = 20;     // 작업 30개, 1..20 beat
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
