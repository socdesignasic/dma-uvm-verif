// unit_rand_test : random gaps in, random backpressure out, per-beat random side
class unit_rand_test extends unit_base_test;
  `uvm_component_utils(unit_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items                 = 2000;
    max_delay               = 5;
    zero_delay_pct          = 60;
    cfg.out_cfg.ready_pct   = 70;
    cfg.out_cfg.stall_pct   = 3;
    cfg.out_cfg.max_stall   = 20;
  endfunction
endclass
