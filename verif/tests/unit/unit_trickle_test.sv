// unit_trickle_test : sparse input, always-ready output: runs empty most of the time
class unit_trickle_test extends unit_base_test;
  `uvm_component_utils(unit_trickle_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items        = 300;
    max_delay      = 20;
    zero_delay_pct = 10;
  endfunction
endclass
