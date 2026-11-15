// unit_post_reset_test : 리셋이 풀리는 첫 사이클부터 valid를 켬 (BUG-001 재현)
class unit_post_reset_test extends unit_base_test;
  `uvm_component_utils(unit_post_reset_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_items                    = 50;
    cfg.in_cfg.post_reset_idle = 0;
  endfunction
endclass
