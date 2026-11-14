// dma_base_test : builds the env, generates jobs from knobs and runs each with dma_job_seq.
// Derived tests change knobs in configure() or override run_jobs().
//   +N_JOBS=<n>   overrides the number of DMA jobs
class dma_base_test extends uvm_test;
  `uvm_component_utils(dma_base_test)
  dma_env     env;
  dma_env_cfg cfg;

  // job generation knobs (set in configure())
  int unsigned n_jobs     = 1;
  int unsigned min_beats  = 1;
  int unsigned max_beats  = 64;
  int unsigned irq_pct    = 0;      // % of jobs completed by interrupt (rest: polling)
  bit          force_4k   = 0;      // place src/dst so the transfer straddles 4KB pages
  bit [31:0]   mem_base   = 32'h1000_0000;   // as in SW/mem_copy_test.c

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void configure();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = dma_env_cfg::type_id::create("cfg");
    configure();
    if ($value$plusargs("N_JOBS=%d", n_jobs)) `uvm_info("TEST", "N_JOBS overridden by plusarg", UVM_LOW)
    uvm_config_db#(dma_env_cfg)::set(this, "env", "cfg", cfg);
    env = dma_env::type_id::create("env", this);
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    `uvm_info("TEST", $sformatf("jobs=%0d beats=[%0d:%0d] irq=%0d%% force_4k=%0d | slave %s",
              n_jobs, min_beats, max_beats, irq_pct, force_4k, cfg.slv_cfg.convert2string()),
              UVM_LOW)
  endfunction

  // Placement is computed procedurally (XSim 2022.2 `dist`/range solving is
  // unreliable, see verif/README.md). Jobs use disjoint windows so earlier
  // results never alias a later job.
  function dma_job make_job(int unsigned idx);
    dma_job j = dma_job::type_id::create("job");
    bit [31:0] win = mem_base + idx * 32'h0010_0000;          // 1MB window per job
    int unsigned beats = $urandom_range(max_beats, min_beats);
    j.bytes = beats * BEAT;
    if (force_4k) begin
      // start 1..(beats-1) beats before a 4KB boundary so the job straddles it
      j.src = win + 32'h1000 - BEAT * $urandom_range((beats > 1) ? beats - 1 : 1, 1);
      j.dst = win + 32'h8_0000 + 32'h1000 - BEAT * $urandom_range((beats > 1) ? beats - 1 : 1, 1);
    end else begin
      j.src = win + BEAT * $urandom_range(32'h3_0000 / BEAT, 0);
      j.dst = win + 32'h8_0000 + BEAT * $urandom_range(32'h3_0000 / BEAT, 0);
    end
    case ($urandom_range(9))
      0:       j.value = 0;
      1:       j.value = 32'hFF;
      2:       j.value = 1;
      default: j.value = $urandom;     // upper 24 bits must be ignored by the DUT
    endcase
    j.mode = ($urandom_range(99) < irq_pct) ? DONE_IRQ : DONE_POLL;
    return j;
  endfunction

  // run one job through dma_job_seq on the AXI4-Lite sequencer
  task run_job(dma_job j);
    dma_job_seq seq = dma_job_seq::type_id::create("job_seq");
    seq.env = env;
    seq.job = j;
    seq.start(env.axil_agt.sqr);
  endtask

  virtual task run_jobs();
    for (int unsigned i = 0; i < n_jobs; i++)
      run_job(make_job(i));
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait_reset();
    run_jobs();
    env.clocks(20);
    phase.drop_objection(this);
  endtask

  task wait_reset();
    @(posedge env.ctl_vif.rst_n);
    env.clocks(5);
  endtask
endclass
