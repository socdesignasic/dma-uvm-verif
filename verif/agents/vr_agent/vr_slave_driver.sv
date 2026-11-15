// vr_slave_driver : 랜덤 backpressure와 가끔 긴 stall을 넣어 ready 구동
class vr_slave_driver extends uvm_component;
  `uvm_component_utils(vr_slave_driver)
  vr_vif vif;
  vr_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.ready <= 1'b0;
    @(vif.scb iff !vif.rst);
    forever begin
      if (cfg.max_stall > 0 && $urandom_range(99) < cfg.stall_pct) begin
        vif.scb.ready <= 1'b0;
        repeat ($urandom_range(cfg.max_stall, 1)) @(vif.scb);
      end else begin
        vif.scb.ready <= ($urandom_range(99) < cfg.ready_pct);
        @(vif.scb);
      end
    end
  endtask
endclass
