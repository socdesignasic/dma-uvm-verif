// dma_long_job_test : 64KB(8192 beat) 작업 하나, 중간 정도 backpressure
class dma_long_job_test extends dma_base_test;         // 기본 테스트 상속
  `uvm_component_utils(dma_long_job_test)              // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 1; min_beats = 8192; max_beats = 8192;  // 8192 beat 작업 하나
    cfg.slv_cfg.ar_ready_pct = 80;                  // ARREADY 80%
    cfg.slv_cfg.w_ready_pct  = 80;                  // WREADY 80%
    cfg.slv_cfg.r_gap_pct    = 10;                  // R beat 앞 빈 사이클 10%
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
