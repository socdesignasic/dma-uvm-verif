// dma_smoke_test : 32 beat 작업 하나, backpressure 없음
class dma_smoke_test extends dma_base_test;         // 기본 테스트 상속
  `uvm_component_utils(dma_smoke_test)              // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 1; min_beats = 32; max_beats = 32;     // 32 beat 작업 하나
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
