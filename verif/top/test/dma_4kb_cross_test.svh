// dma_4kb_cross_test : src와 dst가 4KB 페이지 경계에 걸치도록 배치한 작업 15개 (burst 분할)
class dma_4kb_cross_test extends dma_base_test;           // 기본 테스트 상속
  `uvm_component_utils(dma_4kb_cross_test)                // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 15; min_beats = 2; max_beats = 600; force_4k = 1;  // 작업 15개, 2..600 beat, 4KB 경계에 걸치게 배치
    cfg.slv_cfg.ar_ready_pct = 80;                  // ARREADY 80%
    cfg.slv_cfg.w_ready_pct  = 80;                  // WREADY 80%
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
