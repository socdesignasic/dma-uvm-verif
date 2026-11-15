// unit_trickle_test : 입력은 띄엄띄엄, 출력은 항상 ready: 대부분 비어 있는 상태로 동작
class unit_trickle_test extends unit_base_test;
  `uvm_component_utils(unit_trickle_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items        = 300;
    max_delay      = 20;
    zero_delay_pct = 10;
  endfunction
endclass
