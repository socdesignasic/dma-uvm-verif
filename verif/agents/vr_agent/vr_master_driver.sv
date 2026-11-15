// vr_master_driver : sequence item으로 valid/data/side를 구동하고 ready까지 유지
class vr_master_driver extends uvm_driver #(vr_item);
  `uvm_component_utils(vr_master_driver)
  vr_vif vif;
  vr_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.valid <= 1'b0;
    vif.data  <= '0;
    vif.side  <= '0;
    @(vif.mcb iff !vif.rst);
    repeat (cfg.post_reset_idle) @(vif.mcb);
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.delay) @(vif.mcb);
      vif.mcb.valid <= 1'b1;
      vif.mcb.data  <= req.data;
      vif.mcb.side  <= req.side;
      do @(vif.mcb); while (vif.mcb.ready !== 1'b1);
      vif.mcb.valid <= 1'b0;     // back-to-back이면 같은 step에서 다시 덮어씀
      seq_item_port.item_done();
    end
  endtask
endclass
