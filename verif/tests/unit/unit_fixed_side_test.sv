// unit_fixed_side_test : 스트림 전체에서 side 값 고정 (DMA top이 value_to_add를 쓰는 방식)
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
