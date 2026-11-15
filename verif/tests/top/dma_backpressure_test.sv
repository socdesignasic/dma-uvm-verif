// dma_backpressure_test : 64..400 beat 작업 6개, AR/W/R/B를 심하게 막고 지연도 큼
class dma_backpressure_test extends dma_base_test;  // 기본 테스트 상속
  `uvm_component_utils(dma_backpressure_test)       // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 6; min_beats = 64; max_beats = 400;    // 작업 6개, 64..400 beat
    cfg.slv_cfg.ar_ready_pct  = 20;                 // ARREADY 20%
    cfg.slv_cfg.w_ready_pct   = 30;                 // WREADY 30%
    cfg.slv_cfg.r_gap_pct     = 50;                 // R beat 앞 빈 사이클 50%
    cfg.slv_cfg.max_r_latency = 40;                 // 첫 R beat 지연 최대 40사이클
    cfg.slv_cfg.max_b_latency = 40;                 // B 응답 지연 최대 40사이클
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
