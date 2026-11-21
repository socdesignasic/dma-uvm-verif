// dma_reset_test : 테스트 중간 리셋 3경우 (PASS 테스트). 리셋 배관(dma_reset_if, dma_reset_vseq, slave driver/monitor,
//   axil_monitor)과 predictor/scoreboard 리셋 처리(실행 중 job 중단, 리셋 값 예측)가 함께 도는 곳
//   경우 1: job 0 (IRQ 모드: GIE/IER까지 리셋 값이 아닌 값으로) 끝까지 -> idle에서 리셋 -> 레지스터 10개 읽기 -> job 1
//   경우 2: B 지연 min=max=B_LAT -> job 2 start (완료를 기다리지 않음) -> 마지막 W handshake 뒤, 마지막 B 전에 리셋
//           -> 리셋 해제 에지부터 QUIET 에지 동안 m00 관찰 -> 레지스터 10개 읽기 -> B 지연 되돌림 -> job 3
//   경우 3: job 4 (IRQ 모드, 완료를 기다리지 않음 = 아무도 ISR을 읽지 않음) -> interrupt=1 (ISR set)인 채 리셋
//           -> 레지스터 10개 읽기 (ISR=0, AP_CTRL.done=0) -> job 5
//   레지스터 10개 읽기는 RAL 내장 uvm_reg_hw_reset_seq (dma_reg_reset_test와 같음, 리셋 해제 5클럭 뒤)
//   검사는 기존 그대로 (이 테스트는 검사를 더하거나 빼지 않음):
//     읽기값 32비트와 interrupt 핀 -> dma_predictor (리셋 뒤 쓴 적 없는 레지스터는 REG_RESET, 핀은 매 에지 IRQ)
//     m00 버스와 메모리 -> dma_scoreboard (리셋으로 중단된 job은 [SB_JOB] ABORTED 정보, 리셋 뒤 job 없는 활동은 SB_NO_JOB_BUS)
//     내장 sequence의 mirror 비교 (RegModel)
//   도달 확인 (버스 관찰, bus_watch/irq_watch): 리셋을 TB가 처음 본 에지(DUT는 아직 리셋 전 상태)의 m00 누적 수와 VALID,
//   interrupt 핀을 남기고, 경우마다 노린 상태였는지 봄. 아니면 SCENARIO_MISS
//     경우 1: 그 에지에 m00 VALID(AR/AW/W) 0, 경우 시작 뒤 AW 수 = B 수, AR beat 합 = R beat 수 (진행 중 전송 없음)
//     경우 2: 그 에지에 job 2의 W beat 수 = job beat 수, B 수 < AW 수. predictor와 scoreboard가 job을 하나씩 중단
//     경우 3: 그 에지에 interrupt 핀 1, job 4 start 뒤 ISR 읽기 0번
//     모든 경우: 리셋 뒤 읽기 중 리셋 값 검사(REG_RESET)로 비교한 수(dma_predictor.n_rd_reset 증가분) >= 10
//   경우 2의 조용한 구간: 해제 에지부터 QUIET 에지 동안의 m00 handshake와 DUT VALID 사이클 수를 [RESET_TEST] 줄로 남김.
//     판정은 scoreboard의 SB_NO_JOB_BUS (slave ready 100%라 DUT VALID는 바로 handshake가 됨)
class dma_reset_test extends dma_base_test;         // 기본 테스트 상속
  `uvm_component_utils(dma_reset_test)              // factory 등록
  localparam int unsigned B_LAT     = 40;           // 경우 2의 B 지연 (마지막 W -> BVALID, 하한 = 상한)
  localparam int unsigned QUIET     = 100;          // 경우 2: 리셋 해제 뒤 관찰 에지 수
  localparam int unsigned N_REGS    = 10;           // 리셋 뒤 리셋 값 검사로 비교해야 하는 읽기 수 (레지스터 10개)
  localparam int unsigned RST_CYCLES = 16;          // 리셋 길이 (dma_reset_vseq n_cycles 기본값과 같음)

  // m00 버스 누적 수 (bus_watch가 매 에지 갱신). 리셋 에지의 값을 복사해 둠
  typedef struct {
    int unsigned     ar, ar_beats, r;               // AR handshake 수, AR beat 합, R handshake 수
    int unsigned     aw, w, b;                      // AW handshake 수, W handshake 수, B handshake 수
    int unsigned     valid;                         // DUT가 AR/AW/W VALID 중 하나라도 낸 에지 수
    longint unsigned edge_n;                        // 본 에지 수
    bit              m00_valid;                     // 이 에지 표본에서 DUT AR/AW/W VALID 중 하나라도 1
    time             t;                             // 에지 시각
  } bus_cnt_t;

  bus_cnt_t    cnt;                                 // 지금 누적 값
  bus_cnt_t    at_fall;                             // 마지막 리셋을 TB가 처음 본 에지의 값 (그 에지 handshake는 없음)
  bus_cnt_t    at_rel;                              // 마지막 리셋이 풀린 첫 에지의 값 (그 에지 handshake 세기 전)
  int unsigned n_fall;                              // bus_watch가 본 리셋 수
  logic        irq_at_fall;                         // 마지막 리셋을 처음 본 에지의 interrupt 핀 표본
  time         t_irq_fall;                          // interrupt 핀이 마지막으로 1 -> 0이 된 에지 시각
  int unsigned n_miss;                              // SCENARIO_MISS 수 (요약용)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 6; min_beats = 8; max_beats = 64;      // job 6개 (창 0..5), 8~64 beat
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // 경우 1 -> 2 -> 3
    fork                                            // 버스 관찰 시작 (전원 리셋이 끝난 뒤)
      bus_watch();                                  // m00
      irq_watch();                                  // interrupt 핀
    join_none                                       // 기다리지 않음
    case_idle();                                    // 경우 1
    case_b_pending();                               // 경우 2
    case_irq_pending();                             // 경우 3
    `uvm_info("RESET_TEST", $sformatf("summary: resets=%0d | predictor aborted=%0d reset-value reads=%0d | scoreboard aborted=%0d | scenario misses=%0d",  // 요약
                                      n_fall, env.pred.n_aborted, env.pred.n_rd_reset, env.sb.n_aborted, n_miss), UVM_LOW)  // 값들
  endtask                                           // run_jobs 끝

  // ---------------- 경우 1: idle 중 리셋 ----------------
  task case_idle();                                 // 경우 1
    bus_cnt_t    s0 = cnt;                          // 경우 시작 값
    dma_job      j  = make_job(0);                  // job 0
    int unsigned n_set;                             // 리셋 직전 리셋 값이 아닌 레지스터 수 (mirror = 버스 관찰값)
    j.mode = DONE_IRQ;                              // GIE=1, IER=1까지 씀 (리셋이 지울 값)
    `uvm_info("RESET_TEST", "case1: job, then reset while idle", UVM_LOW)  // 진행 로그
    run_job(j);                                     // 끝까지 (ISR 읽기, idle 대기)
    env.clocks(10);                                 // idle 유지
    n_set = regs_not_at_reset();                    // 리셋할 값이 있는지
    do_reset("case1");                              // 리셋
    `uvm_info("RESET_TEST", $sformatf("case1: reset @%0t: m00 VALID=%0d AW=%0d B=%0d AR beats=%0d R beats=%0d | registers not at reset value before reset=%0d",  // 도달 로그
                                      at_fall.t, at_fall.m00_valid, at_fall.aw - s0.aw, at_fall.b - s0.b,  // 값들
                                      at_fall.ar_beats - s0.ar_beats, at_fall.r - s0.r, n_set), UVM_LOW)  // (계속)
    if (at_fall.m00_valid || at_fall.aw - s0.aw != at_fall.b - s0.b || at_fall.ar_beats - s0.ar_beats != at_fall.r - s0.r)  // 진행 중 전송이 있었으면
      miss("case1: m00 transfer in progress at the reset edge (not idle)");  // idle 리셋이 아님
    if (n_set == 0) miss("case1: all registers already at reset value before the reset");  // 리셋이 지울 값이 없음
    read_regs_after_reset("case1");                 // 레지스터 10개 (REG_RESET)
    run_job(make_job(1));                           // 리셋 뒤 job
  endtask                                           // case_idle 끝

  // ---------------- 경우 2: 마지막 W 뒤, 마지막 B 전 리셋 ----------------
  task case_b_pending();                            // 경우 2
    bus_cnt_t    s0;                                // 경우 시작 값
    dma_job      j = make_job(2);                   // job 2
    int unsigned lo = cfg.slv_cfg.min_b_latency, hi = cfg.slv_cfg.max_b_latency;  // 되돌릴 B 지연
    int unsigned ab_pred = env.pred.n_aborted, ab_sb = env.sb.n_aborted;  // 경우 전 중단 수
    bit          ok;                                // 마지막 W까지 갔는지
    time         t_last_w;                          // 마지막 W를 본 시각
    bus_cnt_t    q;                                 // 조용한 구간 끝 값
    cfg.slv_cfg.min_b_latency = B_LAT;              // B 지연 고정 (마지막 W 뒤 B까지 B_LAT 사이클 이상)
    cfg.slv_cfg.max_b_latency = B_LAT;              // (계속)
    `uvm_info("RESET_TEST", $sformatf("case2: B latency %0d, reset after the last W and before the last B", B_LAT), UVM_LOW)  // 진행 로그
    s0 = cnt;                                       // 경우 시작 값
    start_job(j);                                   // 메모리, 레지스터, start (완료를 기다리지 않음)
    wait_w(s0.w + j.beats(), budget_ns(j), ok);     // 이 job의 W beat를 모두 볼 때까지
    t_last_w = $time;                               // 시각
    if (!ok) miss($sformatf("case2: only %0d of %0d W beats seen within the time budget", cnt.w - s0.w, j.beats()));  // 못 감 (리셋은 그대로)
    do_reset("case2");                              // 리셋 (AXI-Lite 접근이 없어 2에지 뒤)
    `uvm_info("RESET_TEST", $sformatf("case2: last W seen @%0t, reset @%0t: W beats=%0d/%0d AW=%0d B=%0d (B pending=%0d) | aborted: predictor=%0d scoreboard=%0d",  // 도달 로그
                                      t_last_w, at_fall.t, at_fall.w - s0.w, j.beats(), at_fall.aw - s0.aw, at_fall.b - s0.b,  // 값들
                                      int'(at_fall.aw - s0.aw) - int'(at_fall.b - s0.b),  // 남은 B
                                      env.pred.n_aborted - ab_pred, env.sb.n_aborted - ab_sb), UVM_LOW)  // 중단 수
    if (at_fall.w - s0.w != j.beats() || at_fall.b - s0.b >= at_fall.aw - s0.aw)  // 마지막 W 전이거나 마지막 B 뒤면
      miss("case2: reset edge is not between the last W and the last B");  // 노린 상태 아님
    if (env.pred.n_aborted - ab_pred != 1 || env.sb.n_aborted - ab_sb != 1)  // 실행 중 job을 중단하지 않았으면
      miss($sformatf("case2: expected 1 aborted job, predictor=%0d scoreboard=%0d", env.pred.n_aborted - ab_pred, env.sb.n_aborted - ab_sb));  // 중단 경로를 못 탐
    // 해제 에지부터 QUIET 에지 동안 관찰 (handshake 판정은 scoreboard SB_NO_JOB_BUS)
    while (cnt.edge_n < at_rel.edge_n + QUIET) @(env.mem_agt.vif.moncb);  // 해제 에지 + QUIET까지
    q = cnt;                                        // 구간 끝 값
    `uvm_info("RESET_TEST", $sformatf("case2: %0d edges after reset release (@%0t..@%0t): m00 AR=%0d AW=%0d W=%0d B=%0d, DUT VALID edges=%0d",  // 조용한 구간 로그
                                      q.edge_n - at_rel.edge_n, at_rel.t, q.t, q.ar - at_rel.ar, q.aw - at_rel.aw,  // 값들
                                      q.w - at_rel.w, q.b - at_rel.b, q.valid - at_rel.valid), UVM_LOW)  // (계속)
    read_regs_after_reset("case2");                 // 레지스터 10개 (REG_RESET)
    cfg.slv_cfg.min_b_latency = lo;                 // B 지연 되돌림
    cfg.slv_cfg.max_b_latency = hi;                 // (계속)
    run_job(make_job(3));                           // 리셋 뒤 job
  endtask                                           // case_b_pending 끝

  // ---------------- 경우 3: ISR set, interrupt 1인 채 리셋 ----------------
  task case_irq_pending();                          // 경우 3
    dma_job      j = make_job(4);                   // job 4
    int unsigned isr0;                              // job 전 ISR 읽기 수
    bit          ok;                                // interrupt가 왔는지
    j.mode = DONE_IRQ;                              // GIE=1, IER=1 (ap_done)
    `uvm_info("RESET_TEST", "case3: job in IRQ mode, nobody reads ISR, reset while interrupt=1", UVM_LOW)  // 진행 로그
    isr0 = env.pred.n_rd_isr;                       // job 전 ISR 읽기 수
    start_job(j);                                   // 메모리, 레지스터, start (완료를 기다리지 않음)
    wait_irq(budget_ns(j), ok);                     // interrupt = 1까지
    if (!ok) miss("case3: no interrupt within the time budget");  // 못 감 (리셋은 그대로)
    env.clocks(10);                                 // interrupt 유지 (ISR을 읽지 않음)
    do_reset("case3");                              // 리셋
    `uvm_info("RESET_TEST", $sformatf("case3: reset @%0t: interrupt=%b, ISR reads since job start=%0d | interrupt fell @%0t",  // 도달 로그
                                      at_fall.t, irq_at_fall, env.pred.n_rd_isr - isr0, t_irq_fall), UVM_LOW)  // 값들
    if (irq_at_fall !== 1'b1 || env.pred.n_rd_isr != isr0)  // interrupt가 1이 아니었거나 ISR을 읽었으면
      miss("case3: interrupt was not pending (ISR set, unread) at the reset edge");  // 노린 상태 아님
    // 리셋 뒤 interrupt = 0은 dma_predictor가 해제 다음 에지부터 매 에지 비교 (IRQ). 여기서는 내려간 시각만 남김
    read_regs_after_reset("case3");                 // 레지스터 10개 (ISR=0, AP_CTRL.done=0을 REG_RESET로)
    run_job(make_job(5));                           // 리셋 뒤 job
  endtask                                           // case_irq_pending 끝

  // ---------------- 도우미 ----------------
  // job의 메모리 준비, 레지스터, start만 (완료 대기 없음: 테스트가 버스를 보며 리셋 시점을 정함)
  task start_job(dma_job j);                        // job
    dma_job_vseq seq = dma_job_vseq::type_id::create("job_vseq");  // 작업 virtual sequence
    seq.job     = j;                                // job
    seq.do_wait = 0;                                // 완료 대기 안 함
    seq.start(env.vsqr);                            // start까지 실행
  endtask                                           // start_job 끝

  // 리셋 한 번 (dma_reset_vseq: AXI-Lite lock, 진행 중 접근 끝난 뒤 RST_CYCLES, 해제 5클럭 뒤 unlock)
  task do_reset(string tag);                        // 경우 이름
    dma_reset_vseq rs = dma_reset_vseq::type_id::create({"reset_vseq_", tag});  // 리셋 sequence
    int unsigned   k  = n_fall;                     // 리셋 전 본 수
    rs.n_cycles = RST_CYCLES;                       // 리셋 길이
    rs.start(env.vsqr);                             // 실행 (해제 뒤 5클럭까지)
    if (n_fall != k + 1) miss($sformatf("%s: bus_watch saw %0d resets, expected 1", tag, n_fall - k));  // 리셋을 못 봄
  endtask                                           // do_reset 끝

  // 리셋 뒤 레지스터 10개 읽기 (RAL 내장 uvm_reg_hw_reset_seq, frontdoor). 비교는 dma_predictor (REG_RESET)와 내장 mirror 비교
  task read_regs_after_reset(string tag);           // 경우 이름
    uvm_reg_hw_reset_seq seq = uvm_reg_hw_reset_seq::type_id::create("hw_reset_seq");  // 내장 리셋 값 sequence
    int unsigned         r0  = env.pred.n_rd_reset; // 읽기 전 리셋 값 비교 수
    int unsigned         n;                         // 이번 리셋 값 비교 수
    seq.model = env.regmodel;                       // 대상 블록
    seq.start(null);                                // frontdoor 접근은 map의 sequencer(AXI4-Lite)로 감
    env.clocks(2);                                  // 마지막 R이 predictor에 도착할 때까지
    n = env.pred.n_rd_reset - r0;                   // 이번 수
    `uvm_info("RESET_TEST", $sformatf("%s: %0d register reads compared against reset values (REG_RESET)", tag, n), UVM_LOW)  // 결과 로그
    if (n < N_REGS) miss($sformatf("%s: only %0d reset-value reads after reset, expected >= %0d", tag, n, N_REGS));  // 리셋 값 검사를 못 탐
  endtask                                           // read_regs_after_reset 끝

  // mirror(버스 관찰로 갱신)가 리셋 값이 아닌 레지스터 수
  function int unsigned regs_not_at_reset();        // 개수
    uvm_reg      regs[$];                           // 레지스터 목록
    int unsigned n;                                 // 개수
    env.regmodel.get_registers(regs);               // 10개
    foreach (regs[i])                               // 레지스터마다
      if (regs[i].get_mirrored_value() != regs[i].get_reset()) n++;  // 리셋 값과 다르면 셈
    return n;                                       // 개수
  endfunction                                       // regs_not_at_reset 끝

  // 완료 대기 시간 한도 (dma_job_vseq::wait_done과 같은 식, ns)
  function longint unsigned budget_ns(dma_job j);   // job
    return 20000 + longint'(j.beats()) * cfg.clk_period_ns * (8 + cfg.slv_cfg.max_r_latency + cfg.slv_cfg.max_b_latency) * 4;  // 20us + beat x 주기 x (8 + 지연 상한) x 4
  endfunction                                       // budget_ns 끝

  // m00 W handshake 누적 수가 target이 될 때까지 (한도 안에 못 가면 ok = 0)
  task wait_w(int unsigned target, longint unsigned limit_ns, output bit ok);  // 목표 누적 수, 한도
    time t_end = $time + limit_ns * 1ns;            // 끝 시각
    ok = 0;                                         // 기본: 못 감
    while ($time < t_end) begin                     // 한도 안
      @(env.mem_agt.vif.moncb);                     // 다음 에지 (bus_watch가 같은 에지를 먼저 셌을 수도, 다음 에지에 볼 수도 있음)
      if (cnt.w >= target) begin                    // 다 봄
        ok = 1;                                     // 감
        return;                                     // 끝
      end                                           // if 끝
    end                                             // while 끝
  endtask                                           // wait_w 끝

  // interrupt 핀이 1이 될 때까지 (한도 안에 못 가면 ok = 0)
  task wait_irq(longint unsigned limit_ns, output bit ok);  // 한도
    time t_end = $time + limit_ns * 1ns;            // 끝 시각
    ok = 0;                                         // 기본: 못 감
    while ($time < t_end) begin                     // 한도 안
      @(env.ctl_vif.moncb);                         // 다음 에지
      if (env.ctl_vif.moncb.interrupt === 1'b1) begin  // interrupt
        ok = 1;                                     // 감
        return;                                     // 끝
      end                                           // if 끝
    end                                             // while 끝
  endtask                                           // wait_irq 끝

  // SCENARIO_MISS: 노린 상태에 가지 못함 (판정 불가)
  function void miss(string why);                   // 이유
    n_miss++;                                       // 수 증가
    `uvm_error("SCENARIO_MISS", why)                // 오류 보고
  endfunction                                       // miss 끝

  // m00 버스를 매 에지 셈. 리셋 에지(@(moncb) 뒤 rst_n=0, monitor와 같은 기준)에는 handshake를 세지 않고,
  // 첫 리셋 에지와 해제 뒤 첫 에지의 누적 값을 남김
  task bus_watch();                                 // m00 관찰
    axi4_vif m = env.mem_agt.vif;                   // m00 interface
    bit      in_rst;                                // 지난 에지가 리셋 에지였는지
    forever begin                                   // 계속 반복
      @(m.moncb);                                   // 매 에지 (값은 에지 직전 표본)
      cnt.edge_n++;                                 // 에지 수
      cnt.t         = $time;                        // 시각
      cnt.m00_valid = (m.moncb.arvalid === 1'b1 || m.moncb.awvalid === 1'b1 || m.moncb.wvalid === 1'b1);  // DUT VALID
      if (cnt.m00_valid) cnt.valid++;               // VALID 에지 수 (리셋 에지 포함)
      if (m.rst_n !== 1'b1) begin                   // 리셋 에지
        if (!in_rst) begin                          // 첫 리셋 에지 (DUT는 아직 리셋 전 상태의 출력)
          at_fall = cnt;                            // 남김
          n_fall++;                                 // 리셋 수
        end                                         // if 끝
        in_rst = 1;                                 // 리셋 중
        continue;                                   // handshake로 보지 않음
      end                                           // if 끝
      if (in_rst) begin                             // 해제 뒤 첫 에지
        at_rel = cnt;                               // 남김 (이 에지 handshake 세기 전)
        in_rst = 0;                                 // 리셋 끝
      end                                           // if 끝
      if (m.moncb.arvalid === 1'b1 && m.moncb.arready === 1'b1) begin  // AR handshake
        cnt.ar++;                                   // 수
        cnt.ar_beats += m.moncb.arlen + 1;          // beat 합
      end                                           // if 끝
      if (m.moncb.rvalid  === 1'b1 && m.moncb.rready  === 1'b1) cnt.r++;  // R handshake
      if (m.moncb.awvalid === 1'b1 && m.moncb.awready === 1'b1) cnt.aw++;  // AW handshake
      if (m.moncb.wvalid  === 1'b1 && m.moncb.wready  === 1'b1) cnt.w++;  // W handshake
      if (m.moncb.bvalid  === 1'b1 && m.moncb.bready  === 1'b1) cnt.b++;  // B handshake
    end                                             // forever 끝
  endtask                                           // bus_watch 끝

  // interrupt 핀을 매 에지 봄 (AXI-Lite clocking block 표본). 첫 리셋 에지의 값과 1 -> 0 시각을 남김
  task irq_watch();                                 // interrupt 관찰
    virtual axil_if c = env.ctl_vif;                // 제어 interface
    bit             in_rst;                         // 지난 에지가 리셋 에지였는지
    logic           prev;                           // 지난 에지의 핀
    forever begin                                   // 계속 반복
      @(c.moncb);                                   // 매 에지 (값은 에지 직전 표본)
      if (c.rst_n !== 1'b1) begin                   // 리셋 에지
        if (!in_rst) irq_at_fall = c.moncb.interrupt;  // 첫 리셋 에지의 핀
        in_rst = 1;                                 // 리셋 중
      end else in_rst = 0;                          // 리셋 아님
      if (prev === 1'b1 && c.moncb.interrupt !== 1'b1) t_irq_fall = $time;  // 1 -> 0
      prev = c.moncb.interrupt;                     // 다음 에지용
    end                                             // forever 끝
  endtask                                           // irq_watch 끝
endclass                                            // 클래스 끝
