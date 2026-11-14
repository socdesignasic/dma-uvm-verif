// axi4_slv_driver : drives the slave side of m00 from/to axi4_mem
//
//   ar_channel -> ar_q -> r_channel
//   aw_channel -> aw_q -.
//   w_channel  -> w_q  -+-> write_engine -> b_q -> b_channel
class axi4_slv_driver extends uvm_component;
  `uvm_component_utils(axi4_slv_driver)
  axi4_vif     vif;
  axi4_slv_cfg cfg;
  axi4_mem     mem;

  axi4_burst ar_q[$], aw_q[$], b_q[$];
  bit [63:0] w_data_q[$];
  bit [7:0]  w_strb_q[$];
  bit        w_last_q[$];
  int unsigned n_rd_beats, n_wr_beats, n_rd_uninit;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function bit pick(int unsigned pct);
    return $urandom_range(99) < pct;
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.awready <= 0; vif.wready <= 0; vif.arready <= 0;
    vif.bvalid  <= 0; vif.bresp  <= 0; vif.bid    <= 0;
    vif.rvalid  <= 0; vif.rdata  <= 0; vif.rlast  <= 0; vif.rresp <= 0; vif.rid <= 0;
    @(vif.cb iff vif.rst_n === 1'b1);
    fork
      ar_channel();
      r_channel();
      aw_channel();
      w_channel();
      write_engine();
      b_channel();
    join
  endtask

  // ---------------- read path ----------------
  task ar_channel();
    bit rdy;
    forever begin
      rdy = pick(cfg.ar_ready_pct);
      vif.cb.arready <= rdy;
      @(vif.cb);
      if (rdy && vif.cb.arvalid === 1'b1) begin
        axi4_burst b = axi4_burst::type_id::create("ar");
        b.is_write = 0;
        b.addr = vif.cb.araddr; b.len = vif.cb.arlen;
        b.size = vif.cb.arsize; b.burst = vif.cb.arburst; b.t = $time;
        ar_q.push_back(b);
      end
    end
  endtask

  task r_channel();
    axi4_burst b;
    bit [63:0] d;
    forever begin
      while (ar_q.size() == 0) @(vif.cb);
      b = ar_q.pop_front();
      repeat ($urandom_range(cfg.max_r_latency, 0)) @(vif.cb);
      for (int i = 0; i < b.beats(); i++) begin
        while (pick(cfg.r_gap_pct)) begin
          vif.cb.rvalid <= 0;
          @(vif.cb);
        end
        if (!mem.rd64(b.addr + i * 8, d)) begin
          n_rd_uninit++;
          `uvm_error("AXI_RD_UNINIT", $sformatf("read of uninitialised memory at 0x%08h (%s)",
                                                 b.addr + i * 8, b.convert2string()))
        end
        vif.cb.rvalid <= 1; vif.cb.rdata <= d; vif.cb.rlast <= (i == b.beats() - 1);
        vif.cb.rresp  <= 0; vif.cb.rid   <= 0;
        do @(vif.cb); while (vif.cb.rready !== 1'b1);
        n_rd_beats++;
      end
      vif.cb.rvalid <= 0;
      vif.cb.rlast  <= 0;
    end
  endtask

  // ---------------- write path ----------------
  task aw_channel();
    bit rdy;
    forever begin
      if (cfg.aw_fixed_wait > 0) begin       // deterministic AW stall
        vif.cb.awready <= 0;
        do @(vif.cb); while (vif.cb.awvalid !== 1'b1);
        repeat (cfg.aw_fixed_wait - 1) @(vif.cb);
        rdy = 1;
      end else
        rdy = pick(cfg.aw_ready_pct);
      vif.cb.awready <= rdy;
      @(vif.cb);
      if (rdy && vif.cb.awvalid === 1'b1) begin
        axi4_burst b = axi4_burst::type_id::create("aw");
        b.is_write = 1;
        b.addr = vif.cb.awaddr; b.len = vif.cb.awlen;
        b.size = vif.cb.awsize; b.burst = vif.cb.awburst; b.t = $time;
        aw_q.push_back(b);
      end
    end
  endtask

  task w_channel();
    bit rdy;
    forever begin
      rdy = pick(cfg.w_ready_pct);
      vif.cb.wready <= rdy;
      @(vif.cb);
      if (rdy && vif.cb.wvalid === 1'b1) begin
        w_data_q.push_back(vif.cb.wdata);
        w_strb_q.push_back(vif.cb.wstrb);
        w_last_q.push_back(vif.cb.wlast);
        n_wr_beats++;
        `uvm_info("AXI_W", $sformatf("W beat #%0d last=%0d (AW pending=%0d)",
                                     n_wr_beats, vif.cb.wlast, aw_q.size()), UVM_DEBUG)
      end
    end
  endtask

  // pairs each AW with its W beats, in order
  task write_engine();
    axi4_burst b;
    bit last;
    forever begin
      while (aw_q.size() == 0) @(vif.cb);
      b = aw_q.pop_front();
      for (int i = 0; i < b.beats(); i++) begin
        while (w_data_q.size() == 0) @(vif.cb);
        last = w_last_q.pop_front();
        if (last != (i == b.beats() - 1))
          `uvm_error("AXI_WLAST", $sformatf("WLAST=%0d on beat %0d of %0d (%s)",
                                            last, i, b.beats(), b.convert2string()))
        mem.wr64(b.addr + i * 8, w_data_q.pop_front(), w_strb_q.pop_front());
      end
      b_q.push_back(b);
    end
  endtask

  task b_channel();
    axi4_burst b;
    forever begin
      while (b_q.size() == 0) @(vif.cb);
      b = b_q.pop_front();
      repeat ($urandom_range(cfg.max_b_latency, 0)) @(vif.cb);
      vif.cb.bvalid <= 1; vif.cb.bresp <= 0; vif.cb.bid <= 0;
      do @(vif.cb); while (vif.cb.bready !== 1'b1);
      vif.cb.bvalid <= 0;
    end
  endtask

  // nothing may be left half-done when the test ends
  function void check_phase(uvm_phase phase);
    if (ar_q.size() || aw_q.size() || b_q.size() || w_data_q.size())
      `uvm_error("AXI_PENDING", $sformatf("pending at end: AR=%0d AW=%0d W beats=%0d B=%0d",
                                          ar_q.size(), aw_q.size(), w_data_q.size(), b_q.size()))
  endfunction
endclass
