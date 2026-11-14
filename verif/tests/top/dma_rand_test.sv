// dma_rand_test : 15 jobs of 1..600 beats, 50% IRQ completion, moderate backpressure on AR/W/R/B
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
