// dma_irq_test : 작업 6개, 모두 인터럽트(GIE/IER/ISR)로 완료
class dma_irq_test extends dma_base_test;           // 기본 테스트 상속
  `uvm_component_utils(dma_irq_test)                // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 6; min_beats = 1; max_beats = 100; irq_pct = 100;  // 작업 6개, 1..100 beat, 모두 인터럽트 완료
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
