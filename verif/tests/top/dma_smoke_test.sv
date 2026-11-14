// dma_smoke_test : one 32-beat job, no backpressure
class dma_smoke_test extends dma_base_test;
  `uvm_component_utils(dma_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 1; min_beats = 32; max_beats = 32;
  endfunction
endclass
