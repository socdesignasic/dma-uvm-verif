// dma_job_seq : runs one DMA job end to end and has it checked
//   1. memory: random source, guard bands, destination pre-poisoned with ~expected
//   2. program registers (same order as SW/mem_copy_test.c), wait idle, ap_start
//   3. wait done by polling AP_CTRL or by interrupt, bounded by a time budget
//   4. scoreboard check + coverage sample, wait idle again
class dma_job_seq extends axil_base_seq;
  `uvm_object_utils(dma_job_seq)
  dma_env env;      // set by the test before start()
  dma_job job;      // set by the test before start()

  static int unsigned next_id;

  function new(string name = "dma_job_seq");
    super.new(name);
  endfunction

  virtual task body();
    axi4_mem         mem = env.mem_agt.mem;
    bit [7:0]        snap[];
    bit [7:0]        guard_val = 8'hA5;
    bit [31:0]       v;
    longint unsigned budget_ns;
    bit              timed_out;

    job.id = next_id++;
    `uvm_info("JOB", {"start ", job.convert2string()}, UVM_LOW)

    // 1. memory
    snap = new[job.bytes];
    foreach (snap[i]) begin
      snap[i] = $urandom;
      mem.wr8(job.src + i, snap[i]);
    end
    for (int unsigned g = 1; g <= GUARD; g++) begin
      mem.wr8(job.dst - g, guard_val);
      mem.wr8(job.dst + job.bytes - 1 + g, guard_val);
    end
    foreach (snap[i])
      mem.wr8(job.dst + i, ~dma_scoreboard::model_byte(snap[i], job.value));
    env.sb.start_job(job);

    // 2. program + start
    write_reg(ADDR_AXI00_PTR0,         0);
    write_reg(ADDR_VALUE_TO_ADD,       job.value);
    write_reg(ADDR_RDMA_TRANSFER_BYTE, job.bytes);
    write_reg(ADDR_RDMA_MEM_PTR,       job.src);
    write_reg(ADDR_WDMA_TRANSFER_BYTE, job.bytes);
    write_reg(ADDR_WDMA_MEM_PTR,       job.dst);
    write_reg(ADDR_GIE, job.mode == DONE_IRQ);
    write_reg(ADDR_IER, job.mode == DONE_IRQ ? 2'b01 : 2'b00);
    do read_reg(ADDR_AP_CTRL, v); while (!v[AP_IDLE]);
    write_reg(ADDR_AP_CTRL, 1 << AP_START);

    // 3. wait done
    budget_ns = 20000 + longint'(job.beats()) * env.cfg.clk_period_ns *
                (8 + env.cfg.slv_cfg.max_r_latency + env.cfg.slv_cfg.max_b_latency) * 4;
    fork
      begin
        if (job.mode == DONE_IRQ) begin
          wait (env.ctl_vif.interrupt === 1'b1);
          read_reg(ADDR_ISR, v);
          if (v[ISR_AP_DONE] !== 1'b1) `uvm_error("IRQ", $sformatf("ISR=0x%0h, ap_done bit not set", v))
          env.clocks(3);
          if (env.ctl_vif.interrupt !== 1'b0) `uvm_error("IRQ", "interrupt still high after ISR read")
          read_reg(ADDR_AP_CTRL, v);
          if (v[AP_DONE] !== 1'b1) `uvm_error("IRQ", "AP_CTRL.done not set on interrupt")
        end else begin
          do read_reg(ADDR_AP_CTRL, v); while (!v[AP_DONE]);        // poll done (COR)
          if (env.ctl_vif.interrupt !== 1'b0) `uvm_error("IRQ", "interrupt asserted with GIE=0")
        end
      end
      begin
        #(budget_ns * 1ns);
        timed_out = 1;
      end
    join_any
    disable fork;
    if (timed_out) begin
      `uvm_error("JOB_TIMEOUT", $sformatf("%s: not done after %0d ns (rd beats=%0d wr beats=%0d)",
                 job.convert2string(), budget_ns, env.mem_agt.drv.n_rd_beats, env.mem_agt.drv.n_wr_beats))
      return;
    end

    // 4. check (write responses are already in; let the bus settle first)
    env.clocks(5);
    env.sb.check_job(job, snap, guard_val);
    env.cov.sample_job(job);
    do read_reg(ADDR_AP_CTRL, v); while (!v[AP_IDLE]);       // back to idle
  endtask
endclass
