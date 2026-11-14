// unit_backpressure_test : heavy backpressure: fill the FIFO, exercise skid state
class unit_backpressure_test extends unit_base_test;
  `uvm_component_utils(unit_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items                 = 1000;
    cfg.out_cfg.ready_pct   = 25;
    cfg.out_cfg.stall_pct   = 10;
    cfg.out_cfg.max_stall   = 80;
  endfunction
endclass
