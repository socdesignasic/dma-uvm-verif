// dma_4kb_test : 15 jobs placed so src and dst straddle 4KB pages (burst split)
class dma_4kb_test extends dma_base_test;
  `uvm_component_utils(dma_4kb_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 15; min_beats = 2; max_beats = 600; force_4k = 1;
    cfg.slv_cfg.ar_ready_pct = 80;
    cfg.slv_cfg.w_ready_pct  = 80;
  endfunction
endclass
