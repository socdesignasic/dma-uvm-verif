// dma_rand_test : 1..600 beat 작업 15개, 50%는 인터럽트로 완료, AR/W/R/B 중간 정도 backpressure
class dma_rand_test extends dma_base_test;
  `uvm_component_utils(dma_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 15; min_beats = 1; max_beats = 600; irq_pct = 50;
    cfg.slv_cfg.ar_ready_pct  = 70;
    cfg.slv_cfg.w_ready_pct   = 70;
    cfg.slv_cfg.r_gap_pct     = 20;
    cfg.slv_cfg.max_r_latency = 10;
    cfg.slv_cfg.max_b_latency = 10;
  endfunction
endclass
