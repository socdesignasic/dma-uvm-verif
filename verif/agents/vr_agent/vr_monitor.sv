// vr_monitor : valid&&ready handshake마다 vr_item 하나를 내보냄
class vr_monitor extends uvm_monitor;
  `uvm_component_utils(vr_monitor)
  vr_vif vif;
  uvm_analysis_port #(vr_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(vif.moncb);
      if (vif.moncb.rst !== 1'b0) continue;
      if (vif.moncb.valid === 1'b1 && vif.moncb.ready === 1'b1) begin
        vr_item t = vr_item::type_id::create("t");
        t.data = vif.moncb.data;
        t.side = vif.moncb.side;
        `uvm_info("VR_MON", t.convert2string(), UVM_HIGH)
        ap.write(t);
      end
    end
  endtask
endclass
