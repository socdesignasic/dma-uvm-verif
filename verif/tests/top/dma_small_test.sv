// dma_small_test : 30 jobs of 1..20 beats: partial bursts, single beat
class dma_small_test extends dma_base_test;
  `uvm_component_utils(dma_small_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 30; min_beats = 1; max_beats = 20;
  endfunction
endclass
