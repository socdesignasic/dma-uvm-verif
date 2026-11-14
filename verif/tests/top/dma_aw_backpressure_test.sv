// dma_aw_backpressure_test : BUG-002 reproducer. AWREADY backpressure lets W beats go out before their AW,
// the WDMA burst counter misses them, WLAST lands late and ap_done never comes.
// All other tests keep AWREADY=1 (see verif/BUGS.md) so they still verify the rest.
class dma_aw_backpressure_test extends dma_base_test;
  `uvm_component_utils(dma_aw_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 1; min_beats = 64; max_beats = 64;
    cfg.slv_cfg.aw_fixed_wait = 40;   // W data is always ready before AW is accepted
  endfunction
endclass
