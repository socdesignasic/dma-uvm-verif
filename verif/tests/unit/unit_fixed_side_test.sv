// unit_fixed_side_test : constant side value for the whole stream (how the DMA top uses value_to_add)
class unit_fixed_side_test extends unit_base_test;
  `uvm_component_utils(unit_fixed_side_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items                 = 1000;
    max_delay               = 3;
    zero_delay_pct          = 70;
    fix_side                = 1;
    cfg.out_cfg.ready_pct   = 80;
  endfunction
endclass
