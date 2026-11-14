// axi4_burst : one accepted AR or AW request
class axi4_burst extends uvm_object;
  `uvm_object_utils(axi4_burst)
  bit        is_write;
  bit [31:0] addr;
  bit [7:0]  len;      // beats - 1
  bit [2:0]  size;
  bit [1:0]  burst;
  time       t;

  function new(string name = "axi4_burst");
    super.new(name);
  endfunction

  function int unsigned beats(); return len + 1; endfunction
  function bit [31:0] end_addr(); return addr + beats() * 8; endfunction  // exclusive

  virtual function string convert2string();
    return $sformatf("%s addr=0x%08h len=%0d (%0d beats) size=%0d burst=%0d",
                     is_write ? "AW" : "AR", addr, len, beats(), size, burst);
  endfunction
endclass
