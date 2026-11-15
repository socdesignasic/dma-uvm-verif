// unit_rand_test : 입력은 랜덤 간격, 출력은 랜덤 backpressure, beat마다 side도 랜덤
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
