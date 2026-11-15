// axil_base_seq : AXI4-Lite agent에서 레지스터를 다루는 sequence의 기본 클래스
//   write_reg(addr, data)  /  read_reg(addr, data)
// 응답이 OKAY가 아니면 UVM_ERROR로 보고합니다.
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
    finish_item(t);           // item_done 전에 driver가 data/resp를 채움
    data = t.data;
    if (t.resp != 2'b00)
      `uvm_error("AXIL_RESP", $sformatf("read 0x%03h: resp=%0d", addr, t.resp))
  endtask
endclass
