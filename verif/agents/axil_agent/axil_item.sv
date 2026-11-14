// axil_item : one AXI4-Lite read or write (data/resp filled in by the driver on reads)
class axil_item extends uvm_sequence_item;
  rand bit        write;
  rand bit [11:0] addr;
  rand bit [31:0] data;
  bit      [3:0]  strb = 4'hF;
  bit      [1:0]  resp;

  `uvm_object_utils_begin(axil_item)
    `uvm_field_int(write, UVM_ALL_ON)
    `uvm_field_int(addr,  UVM_ALL_ON)
    `uvm_field_int(data,  UVM_ALL_ON)
    `uvm_field_int(resp,  UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axil_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("%s addr=0x%03h data=0x%08h resp=%0d", write ? "WR" : "RD", addr, data, resp);
  endfunction
endclass
