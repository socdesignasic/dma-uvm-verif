// axil_base_seq : base for register-level sequences on the AXI4-Lite agent.
//   write_reg(addr, data)  /  read_reg(addr, data)
// A non-OKAY response is reported as UVM_ERROR.
class axil_base_seq extends uvm_sequence #(axil_item);
  `uvm_object_utils(axil_base_seq)

  function new(string name = "axil_base_seq");
    super.new(name);
  endfunction

  task write_reg(bit [11:0] addr, bit [31:0] data);
    axil_item t = axil_item::type_id::create("wr");
    start_item(t);
    t.write = 1;
    t.addr  = addr;
    t.data  = data;
    finish_item(t);
    if (t.resp != 2'b00)
      `uvm_error("AXIL_RESP", $sformatf("write 0x%03h: resp=%0d", addr, t.resp))
  endtask

  task read_reg(bit [11:0] addr, output bit [31:0] data);
    axil_item t = axil_item::type_id::create("rd");
    start_item(t);
    t.write = 0;
    t.addr  = addr;
    finish_item(t);           // the driver fills in data/resp before item_done
    data = t.data;
    if (t.resp != 2'b00)
      `uvm_error("AXIL_RESP", $sformatf("read 0x%03h: resp=%0d", addr, t.resp))
  endtask
endclass
