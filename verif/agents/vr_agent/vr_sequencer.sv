// vr_sequencer : sequencer of vr_item (master mode only)
class vr_sequencer extends uvm_sequencer #(vr_item);
  `uvm_component_utils(vr_sequencer)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass
