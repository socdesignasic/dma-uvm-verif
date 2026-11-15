// unit_smoke_test : 양쪽 모두 최대 속도
class unit_smoke_test extends unit_base_test;
  `uvm_component_utils(unit_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items = 50;
  endfunction
endclass
