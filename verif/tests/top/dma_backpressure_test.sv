// dma_backpressure_test : 64..400 beat 작업 6개, AR/W/R/B를 심하게 막고 지연도 큼
class dma_backpressure_test extends dma_base_test;
  `uvm_component_utils(dma_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 6; min_beats = 64; max_beats = 400;
    cfg.slv_cfg.ar_ready_pct  = 20;
    cfg.slv_cfg.w_ready_pct   = 30;
    cfg.slv_cfg.r_gap_pct     = 50;
    cfg.slv_cfg.max_r_latency = 40;
    cfg.slv_cfg.max_b_latency = 40;
  endfunction
endclass
