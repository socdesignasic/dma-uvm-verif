// dma_rand_test : 1..600 beat 작업 15개, 50%는 인터럽트로 완료, AR/W/R/B 중간 정도 backpressure
class dma_rand_test extends dma_base_test;          // 기본 테스트 상속
  `uvm_component_utils(dma_rand_test)               // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 15; min_beats = 1; max_beats = 600; irq_pct = 50;  // 작업 15개, 1..600 beat, 인터럽트 50%
    cfg.slv_cfg.ar_ready_pct  = 70;                 // ARREADY 70%
    cfg.slv_cfg.w_ready_pct   = 70;                 // WREADY 70%
    cfg.slv_cfg.r_gap_pct     = 20;                 // R beat 앞 빈 사이클 20%
    cfg.slv_cfg.max_r_latency = 10;                 // 첫 R beat 지연 최대 10사이클
    cfg.slv_cfg.max_b_latency = 10;                 // B 응답 지연 최대 10사이클
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
