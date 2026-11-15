// axil_agent : sequencer + driver (능동 master)
class axil_agent extends uvm_agent;
  `uvm_component_utils(axil_agent)
  axil_vif       vif;
  axil_sequencer sqr;
  axil_driver    drv;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axil_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})
    sqr = axil_sequencer::type_id::create("sqr", this);
    drv = axil_driver::type_id::create("drv", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.vif = vif;
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
