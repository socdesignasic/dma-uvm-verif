// vr_item : one valid/ready beat (data + sideband) and the idle cycles before it
class vr_item extends uvm_sequence_item;
  rand bit [63:0] data;
  rand bit [31:0] side;
  int unsigned    delay;   // idle cycles before valid (set by the sequence)

  // No constraints here on purpose: XSim 2022.2 `dist` produced badly skewed
  // values (wide 64-bit ranges collapsed below 2^32, 2%-weighted values came
  // out ~50%). Corner-value bias is applied procedurally in vr_stream_seq.

  `uvm_object_utils_begin(vr_item)
    `uvm_field_int(data, UVM_ALL_ON)
    `uvm_field_int(side, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "vr_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("data=0x%016h side=0x%08h", data, side);
  endfunction
endclass
