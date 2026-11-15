// dma_irq_test : 작업 6개, 모두 인터럽트(GIE/IER/ISR)로 완료
class dma_irq_test extends dma_base_test;
  `uvm_component_utils(dma_irq_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 6; min_beats = 1; max_beats = 100; irq_pct = 100;
  endfunction
endclass
