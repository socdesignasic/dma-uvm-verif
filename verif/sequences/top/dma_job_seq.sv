// dma_job_seq : DMA 작업 하나를 처음부터 끝까지 실행하고 검사받음
//   1. 메모리: 원본은 랜덤, 앞뒤 보호 영역, 대상은 ~기대값으로 미리 오염
//   2. 레지스터 설정 (SW/mem_copy_test.c와 같은 순서), idle 대기, ap_start
//   3. AP_CTRL polling 또는 인터럽트로 완료 대기. 시간 제한 있음
//   4. scoreboard 검사 + coverage 샘플링, 다시 idle 대기
class dma_job_seq extends axil_base_seq;
  `uvm_object_utils(dma_job_seq)
  dma_env env;      // start() 전에 test가 설정
  dma_job job;      // start() 전에 test가 설정

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

    // 1. 메모리
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

    // 2. 설정 + 시작
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

    // 3. 완료 대기
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
          do read_reg(ADDR_AP_CTRL, v); while (!v[AP_DONE]);        // done polling (읽으면 지워짐)
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

    // 4. 검사 (쓰기 응답은 이미 다 옴. 버스가 조용해질 때까지 먼저 기다림)
    env.clocks(5);
    env.sb.check_job(job, snap, guard_val);
    env.cov.sample_job(job);
    do read_reg(ADDR_AP_CTRL, v); while (!v[AP_IDLE]);       // 다시 idle
  endtask
endclass
