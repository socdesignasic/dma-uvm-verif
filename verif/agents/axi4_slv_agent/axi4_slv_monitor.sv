// axi4_slv_monitor : 받아들인 AR / AW를 모두 axi4_burst로 내보내고,
// DUT가 낼 수 있는 burst인지 검사 (INCR, 8바이트, 정렬, 16 beat 이하, 4KB 경계 넘지 않음)
class axi4_slv_monitor extends uvm_monitor;
  `uvm_component_utils(axi4_slv_monitor)
  axi4_vif     vif;
  axi4_slv_cfg cfg;
  uvm_analysis_port #(axi4_burst) ar_ap, aw_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ar_ap = new("ar_ap", this);
    aw_ap = new("aw_ap", this);
  endfunction

  function void check_burst(axi4_burst b);
    if (b.burst != 2'b01)
      `uvm_error("AXI_BURST", {"burst type is not INCR: ", b.convert2string()})
    if (b.size != 3'd3)
      `uvm_error("AXI_SIZE", {"size is not 8 bytes: ", b.convert2string()})
    if (b.addr[2:0] != 0)
      `uvm_error("AXI_ALIGN", {"address not 8-byte aligned: ", b.convert2string()})
    if (b.beats() > cfg.max_burst_len)
      `uvm_error("AXI_LEN", {"burst longer than 16 beats: ", b.convert2string()})
    if ((b.addr & 32'hFFF) + b.beats() * 8 > 32'h1000)
      `uvm_error("AXI_4KB", {"burst crosses a 4KB boundary: ", b.convert2string()})
  endfunction

  virtual task run_phase(uvm_phase phase);
    @(vif.moncb iff vif.rst_n === 1'b1);
    forever begin
      @(vif.moncb);
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) begin
        axi4_burst b = axi4_burst::type_id::create("ar");
        b.is_write = 0;
        b.addr = vif.moncb.araddr; b.len = vif.moncb.arlen;
        b.size = vif.moncb.arsize; b.burst = vif.moncb.arburst; b.t = $time;
        `uvm_info("AXI_AR", b.convert2string(), UVM_HIGH)
        check_burst(b);
        ar_ap.write(b);
      end
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) begin
        axi4_burst b = axi4_burst::type_id::create("aw");
        b.is_write = 1;
        b.addr = vif.moncb.awaddr; b.len = vif.moncb.awlen;
        b.size = vif.moncb.awsize; b.burst = vif.moncb.awburst; b.t = $time;
        `uvm_info("AXI_AW", b.convert2string(), UVM_HIGH)
        check_burst(b);
        aw_ap.write(b);
      end
    end
  endtask
endclass
