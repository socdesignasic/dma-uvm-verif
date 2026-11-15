// dma_small_test : 1..20 beat 작업 30개: 덜 찬 burst, beat 하나짜리
class dma_small_test extends dma_base_test;
  `uvm_component_utils(dma_small_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 30; min_beats = 1; max_beats = 20;
  endfunction
endclass
