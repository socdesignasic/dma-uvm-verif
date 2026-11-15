// axil_driver : AXI4-Lite master. 쓰기: AW와 W를 함께 보낸 뒤 B. 읽기: AR 뒤 R.
class axil_driver extends uvm_driver #(axil_item);
  `uvm_component_utils(axil_driver)
  axil_vif vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.awvalid <= 0; vif.wvalid <= 0; vif.bready <= 0;
    vif.arvalid <= 0; vif.rready <= 0;
    vif.awaddr  <= 0; vif.wdata  <= 0; vif.wstrb  <= 0; vif.araddr <= 0;
    @(vif.cb iff vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      if (req.write) do_write(req); else do_read(req);
      `uvm_info("AXIL", req.convert2string(), UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask

  // AW와 W를 동시에 내보내고, 각각 자기 handshake에서 끝남
  task do_write(axil_item t);
    vif.cb.awvalid <= 1; vif.cb.awaddr <= t.addr;
    vif.cb.wvalid  <= 1; vif.cb.wdata  <= t.data; vif.cb.wstrb <= t.strb;
    fork
      begin do @(vif.cb); while (vif.cb.awready !== 1'b1); vif.cb.awvalid <= 0; end
      begin do @(vif.cb); while (vif.cb.wready  !== 1'b1); vif.cb.wvalid  <= 0; end
    join
    vif.cb.bready <= 1;
    do @(vif.cb); while (vif.cb.bvalid !== 1'b1);
    t.resp = vif.cb.bresp;
    vif.cb.bready <= 0;
  endtask

  task do_read(axil_item t);
    vif.cb.arvalid <= 1; vif.cb.araddr <= t.addr;
    do @(vif.cb); while (vif.cb.arready !== 1'b1);
    vif.cb.arvalid <= 0;
    vif.cb.rready  <= 1;
    do @(vif.cb); while (vif.cb.rvalid !== 1'b1);
    t.data = vif.cb.rdata;
    t.resp = vif.cb.rresp;
    vif.cb.rready <= 0;
  endtask
endclass
