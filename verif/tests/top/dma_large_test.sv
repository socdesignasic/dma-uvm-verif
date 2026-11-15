// dma_large_test : 64KB(8192 beat) 작업 하나, 중간 정도 backpressure
class dma_large_test extends dma_base_test;
  `uvm_component_utils(dma_large_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 1; min_beats = 8192; max_beats = 8192;
    cfg.slv_cfg.ar_ready_pct = 80;
    cfg.slv_cfg.w_ready_pct  = 80;
    cfg.slv_cfg.r_gap_pct    = 10;
  endfunction
endclass
