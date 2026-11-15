// dma_base_test : env를 만들고, 설정값으로 작업을 생성해 각각 dma_job_seq로 실행.
// 파생 테스트는 configure()에서 설정값을 바꾸거나 run_jobs()를 override함.
//   +N_JOBS=<n>   DMA 작업 개수를 덮어씀
class dma_base_test extends uvm_test;
  `uvm_component_utils(dma_base_test)
  dma_env     env;
  dma_env_cfg cfg;

  // 작업 생성 설정값 (configure()에서 설정)
  int unsigned n_jobs     = 1;
  int unsigned min_beats  = 1;
  int unsigned max_beats  = 64;
  int unsigned irq_pct    = 0;      // 인터럽트로 완료하는 작업 비율(%) (나머지는 polling)
  bit          force_4k   = 0;      // 전송이 4KB 페이지에 걸치도록 src/dst 배치
  bit [31:0]   mem_base   = 32'h1000_0000;   // SW/mem_copy_test.c와 같음

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

  // 위치는 절차적으로 계산함 (XSim 2022.2의 `dist`/범위 풀이를
  // 믿을 수 없음, verif/README.md 참고). 작업마다 겹치지 않는 영역을 써서
  // 앞 작업 결과가 뒤 작업과 섞이지 않음.
  function dma_job make_job(int unsigned idx);
    dma_job j = dma_job::type_id::create("job");
    bit [31:0] win = mem_base + idx * 32'h0010_0000;          // 작업마다 1MB 영역
    int unsigned beats = $urandom_range(max_beats, min_beats);
    j.bytes = beats * BEAT;
    if (force_4k) begin
      // 4KB 경계보다 1..(beats-1) beat 앞에서 시작해 경계에 걸치게 함
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
      default: j.value = $urandom;     // 위 24비트는 DUT가 무시해야 함
    endcase
    j.mode = ($urandom_range(99) < irq_pct) ? DONE_IRQ : DONE_POLL;
    return j;
  endfunction

  // AXI4-Lite sequencer에서 dma_job_seq로 작업 하나 실행
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
