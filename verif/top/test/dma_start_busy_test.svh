// dma_start_busy_test : H1 가설 확인용 directed test (사양 검사 -> 가설이 맞으면 FAIL)
//   H1: start(int_ap_start)는 level인데 wrapper가 상승 에지 펄스로만 RDMA/WDMA에 넘기고(wrapper.v:132-138), 블록은 IDLE일 때만
//       펄스를 받음(rdma.v:307, wdma.v:325). 작업 중 쓴 start는 버려지고 ap_ready가 오지 않아 int_ap_start=1이 남음(control.v:308-311)
//       -> 그 뒤 start를 다시 써도 에지가 없어 리셋 전까지 아무것도 실행되지 않음.
//       H1b: RDMA만 끝난 구간(RDMA IDLE, WDMA RUN)에 쓴 start는 RDMA만 받아 다음 src를 읽고, 그 데이터가 AW 없이 W로 나감
//   사양 (HLS ap_ctrl_hs): 작업 중 쓴 start는 대기했다가 지금 작업 뒤 실행. idle을 확인한 뒤 쓴 start(SW 절차,
//       mem_copy_test.c:52-57)는 실행. 기대는 dma_predictor의 블록 start 모델(TB 정의)이 냄
//   판정은 기존 검사: predictor(REG_STATUS, IRQ), scoreboard(SB_*), APCTRL_SVA(a_ap_idle_leave), JOB_TIMEOUT. 검사를 바꾸지 않음
//   단계 (단계 사이는 테스트 중간 리셋 dma_reset_vseq. 모든 job은 4KB 정렬(16 beat burst), GIE=1, IER=1):
//     a : A 64 beat start -> A 첫 R handshake +10클럭에 B(32 beat, 다른 src/dst, VALUE는 A와 같음) 레지스터와 AP_CTRL=1
//         -> A 완료 대기 -> B 완료 대기 -> SW 절차로 C(32 beat): idle 확인 -> 레지스터 -> start -> 완료 대기 -> 리셋
//     b : (H1b) W ready 30%, B 지연 0..40. A' 128 beat start -> A' R handshake 128개 +3클럭에 B'(32 beat) 레지스터와 AP_CTRL=1
//         -> A' 완료 대기 -> B' 완료 대기 -> 리셋 -> slave 설정 되돌림
//     c : 일반 job D(32 beat). 리셋으로 복구되므로 PASS해야 함
//   완료는 인터럽트로 기다림 (인터럽트 -> ISR 읽기 -> AP_CTRL 읽기). AP_CTRL은 사건(A, A'의 IDLE 진입) 뒤 RD_DELAY클럭이 지나서만
//   읽음 (ctrl_rd_delay): predictor의 대기 start 사이클(IDLE 진입 +2에 PRE)은 TB 정의라 그 근처 값에 판정이 기대지 않게 함
//   버스 관찰 (m00_watch, ctl_watch, rst_watch): m00 AR/R/B handshake 시각, AW beat 합과 W beat 수, AP_CTRL 쓰기와 읽기 값, 리셋.
//     start 쓰기 W handshake 에지 Ew의 펄스는 Ew+1에 r_ap_start_*로, Ew+2에 블록 is_run으로 감. 블록은 마지막 R(B) 에지 +2부터 IDLE
//     -> RDMA가 펄스를 놓침 = 마지막 R > Ew, 받음 = 마지막 R <= Ew. WDMA가 놓침 = 마지막 B > Ew
//     노린 상태에 못 가면 SCENARIO_MISS:
//       a : Ew까지 A의 R이 남고(마지막 R > Ew) A의 마지막 B 전(> Ew). A가 끝남. C start 쓰기 직전 AP_CTRL 읽기가 idle=1
//       b : Ew까지 A' R이 모두 끝나고(<= Ew) A'의 마지막 B 전(> Ew)
//       리셋마다 리셋을 봄
//   [H1] 줄: start 쓰기 에지의 R/B 수, 완료 뒤 리셋까지 AR 수, AP_CTRL 읽기 값, 리셋 때 AW 없이 남은 W beat 수
class dma_start_busy_test extends dma_base_test;    // 기본 테스트 상속
  `uvm_component_utils(dma_start_busy_test)         // factory 등록
  localparam int unsigned RD_DELAY = 16;            // 사건 뒤 AP_CTRL 읽기까지 최소 클럭 (ISR 읽기 뒤 ctrl_rd_delay)
  localparam int unsigned BURST    = 16;            // 4KB 정렬 job의 burst 길이 (beat)
  localparam int unsigned MAX_WAIT = 100000;        // R handshake를 기다리는 최대 클럭

  // 버스 관찰 결과
  time         ar_t[$], r_t[$], b_t[$];             // m00 AR, R, B handshake 시각
  int unsigned bal_aw, bal_w;                       // 마지막 리셋 뒤 m00 AW beat 합, W beat 수
  time         wr_t[$];                             // AP_CTRL 쓰기 W handshake 시각
  bit [31:0]   wr_d[$];                             // 그 값
  time         rd_t[$];                             // AP_CTRL 읽기 AR 시각
  bit [31:0]   rd_v[$];                             // 읽은 값
  int unsigned n_rst;                               // 본 테스트 중간 리셋 수
  int unsigned orphan_w;                            // 마지막 리셋 때 AW 없이 남은 W beat 수 (W beat 수 - AW beat 합)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual task run_jobs();                          // 단계 a -> b -> c
    fork m00_watch(); ctl_watch(); rst_watch(); join_none  // 버스 관찰 시작
    stage_a();                                      // 작업 중 start (RDMA, WDMA 모두 RUN)
    stage_b();                                      // H1b: RDMA만 끝난 구간 start
    stage_c();                                      // 리셋 뒤 일반 job
  endtask                                           // run_jobs 끝

  // ---- 단계 ----
  task stage_a();                                   // 작업 중 start
    dma_job      a, b, c;                           // A(64), B(32), C(32)
    int unsigned r0, b0, i0;                        // 단계 시작 때 R, B 수, AP_CTRL 읽기 수
    int unsigned nr, nb, n_ar;                      // Ew까지 A의 R, B 수, A 완료 뒤 AR 수
    time         tw, tc, t_done;                    // B start 쓰기, C start 쓰기, A 마지막 B 시각
    bit          ok;                                // 기다린 R handshake에 닿았는지
    a = place(0, 64); b = place(1, 32); c = place(2, 32);  // 위치와 크기
    b.value = a.value;                              // 작업 중 VALUE 변경(H3)과 섞이지 않게 같은 값
    r0 = r_t.size(); b0 = b_t.size(); i0 = rd_v.size();  // 기준 (버스가 조용한 때)
    `uvm_info("H1", $sformatf("a: A %s | B %s | C %s", where(a), where(b), where(c)), UVM_LOW)  // 시작 로그 (job 번호는 [JOB] 줄)
    start_regs(a, 1);                               // A: 메모리, 레지스터, idle 확인, start
    wait_r(r0 + 1, ok);                             // A 첫 R handshake
    if (!ok) begin                                  // 오지 않음
      `uvm_error("SCENARIO_MISS", "a: no R handshake of A")  // A가 시작하지 않음
      return;                                       // 끝
    end                                             // if 끝
    env.clocks(10);                                 // +10클럭
    start_regs(b, 0);                               // B: 메모리, 레지스터, idle 확인 없이 start (A 실행 중)
    tw = last_start();                              // B start 쓰기 에지
    nr = n_le(r_t, tw) - r0;  nb = n_le(b_t, tw) - b0;  // 그 에지까지 A의 R, B 수
    `uvm_info("H1", $sformatf("a: B start written @%0t: A R=%0d/%0d B=%0d/%0d", tw, nr, a.beats(), nb, bursts(a)), UVM_LOW)  // 도달 로그
    if (nr >= a.beats() || nb >= bursts(a))         // RDMA나 WDMA가 이미 끝나 가던 때
      `uvm_error("SCENARIO_MISS", $sformatf("a: B start @%0t not while A runs on both RDMA and WDMA (A R=%0d/%0d B=%0d/%0d)",  // 미도달
                                            tw, nr, a.beats(), nb, bursts(a)))  // 값들
    wait_done(a);                                   // A: 인터럽트 -> ISR -> RD_DELAY -> AP_CTRL
    if (b_t.size() < b0 + bursts(a)) begin          // A의 마지막 B가 없음
      `uvm_error("SCENARIO_MISS", $sformatf("a: A did not finish (B=%0d/%0d)", b_t.size() - b0, bursts(a)))  // 대기 start가 있는 IDLE에 못 감
      t_done = 0;                                   // 모름
    end else t_done = b_t[b0 + bursts(a) - 1];      // A 마지막 B 시각
    wait_done(b);                                   // B: 인터럽트 (가설이 맞으면 JOB_TIMEOUT)
    start_regs(c, 1, 1);                            // C: SW 절차 (idle 확인 -> 레지스터 -> start -> 완료 대기)
    tc = last_start();                              // C start 쓰기 에지
    if (!idle_before(tc, i0))                       // 직전 읽기가 idle=1이 아니면
      `uvm_error("SCENARIO_MISS", $sformatf("a: C start @%0t not after an AP_CTRL read with idle=1", tc))  // SW 절차가 아님
    n_ar = (t_done == 0) ? 0 : ar_t.size() - n_le(ar_t, t_done);  // A 완료 뒤 AR 수
    `uvm_info("H1", $sformatf("a: A done @%0t, AR after A done=%0d (B, C) | AP_CTRL reads:%s", t_done, n_ar, reads_since(i0)), UVM_LOW)  // 요약
    do_reset("a");                                  // 리셋
  endtask                                           // stage_a 끝

  task stage_b();                                   // H1b: RDMA만 끝난 구간 start
    dma_job      a, b;                              // A'(128), B'(32)
    int unsigned r0, b0, i0;                        // 단계 시작 때 R, B 수, AP_CTRL 읽기 수
    int unsigned nr, nb, n_ar, n_ar2;               // Ew까지 A'의 R, B 수, A' 마지막 R 뒤 A' 완료까지 AR 수, A' 완료 뒤 AR 수
    time         tw, t_r, t_done;                   // B' start 쓰기, A' 마지막 R, A' 마지막 B 시각
    bit          ok;                                // 기다린 R handshake에 닿았는지
    int unsigned w_pct0, b_lat0;                    // 바꾸기 전 slave 설정 (단계 끝에 되돌림)
    a = place(3, 128); b = place(4, 32);            // 위치와 크기
    b.value = a.value;                              // 같은 VALUE
    w_pct0 = cfg.slv_cfg.w_ready_pct;               // 원래 W ready 확률
    b_lat0 = cfg.slv_cfg.max_b_latency;             // 원래 B 지연 상한
    cfg.slv_cfg.w_ready_pct   = 30;                 // W를 느리게 (WDMA가 RDMA보다 오래 RUN)
    cfg.slv_cfg.max_b_latency = 40;                 // B 지연 0..40
    r0 = r_t.size(); b0 = b_t.size(); i0 = rd_v.size();  // 기준
    `uvm_info("H1", $sformatf("b: A' %s | B' %s | slave %s", where(a), where(b), cfg.slv_cfg.convert2string()), UVM_LOW)  // 시작 로그
    start_regs(a, 1);                               // A': 메모리, 레지스터, idle 확인, start
    wait_r(r0 + a.beats(), ok);                     // A' R 모두
    if (!ok) begin                                  // 닿지 않음
      `uvm_error("SCENARIO_MISS", $sformatf("b: A' R handshakes %0d/%0d", r_t.size() - r0, a.beats()))  // RDMA가 끝나지 않음
      return;                                       // 끝
    end                                             // if 끝
    t_r = r_t[r0 + a.beats() - 1];                  // A' 마지막 R
    env.clocks(3);                                  // +3클럭
    start_regs(b, 0);                               // B': 메모리, 레지스터, idle 확인 없이 start
    tw = last_start();                              // B' start 쓰기 에지
    nr = n_le(r_t, tw) - r0;  nb = n_le(b_t, tw) - b0;  // 그 에지까지 A'의 R, B 수
    `uvm_info("H1", $sformatf("b: B' start written @%0t: A' R=%0d/%0d (last @%0t) B=%0d/%0d", tw, nr, a.beats(), t_r, nb, bursts(a)), UVM_LOW)  // 도달 로그
    if (nr != a.beats() || nb >= bursts(a))         // RDMA가 아직 돌거나 WDMA가 끝나 가던 때
      `uvm_error("SCENARIO_MISS", $sformatf("b: B' start @%0t not in the RDMA-idle/WDMA-run window (A' R=%0d/%0d B=%0d/%0d)",  // 미도달
                                            tw, nr, a.beats(), nb, bursts(a)))  // 값들
    wait_done(a);                                   // A': 인터럽트 -> ISR -> RD_DELAY -> AP_CTRL
    t_done = (b_t.size() >= b0 + bursts(a)) ? b_t[b0 + bursts(a) - 1] : 0;  // A' 마지막 B (없으면 0)
    wait_done(b);                                   // B': 인터럽트 (가설이 맞으면 JOB_TIMEOUT)
    if (t_done == 0) begin                          // A'가 끝나지 않음
      n_ar  = ar_t.size() - n_le(ar_t, t_r);        // A' 마지막 R 뒤 AR 전부
      n_ar2 = 0;                                    // 없음
    end else begin                                  // 끝남
      n_ar  = n_le(ar_t, t_done) - n_le(ar_t, t_r); // A' 마지막 R 뒤 A' 완료까지
      n_ar2 = ar_t.size() - n_le(ar_t, t_done);     // A' 완료 뒤
    end                                             // if 끝
    `uvm_info("H1", $sformatf("b: A' done @%0t, AR between A' last R and A' done=%0d (B' read early), AR after A' done=%0d | AP_CTRL reads:%s",  // 요약
                              t_done, n_ar, n_ar2, reads_since(i0)), UVM_LOW)  // 값들
    do_reset("b");                                  // 리셋 (AW 없이 남은 W beat 수를 로그)
    cfg.slv_cfg.w_ready_pct   = w_pct0;             // slave 설정 되돌림 (단계 b 전 값)
    cfg.slv_cfg.max_b_latency = b_lat0;             // (같음)
  endtask                                           // stage_b 끝

  task stage_c();                                   // 리셋 뒤 일반 job
    dma_job      d = place(5, 32);                  // D(32)
    int unsigned b0 = b_t.size();                   // 기준
    `uvm_info("H1", $sformatf("c: D %s", where(d)), UVM_LOW)  // 시작 로그
    run_job(d);                                     // 기본 순서 (idle 확인, start, 인터럽트 완료, idle 대기)
    `uvm_info("H1", $sformatf("c: D B=%0d/%0d", b_t.size() - b0, bursts(d)), UVM_LOW)  // 요약 (판정은 scoreboard SB_JOB)
  endtask                                           // stage_c 끝

  // ---- 자극 도우미 (dma_job_vseq 단계 노브) ----
  // job k를 창 k(1MB)의 4KB 정렬 위치에 beats beat로 (값은 기본 방식, 완료는 인터럽트)
  function dma_job place(int unsigned k, int unsigned beats);  // 창 번호, beat 수
    dma_job j = make_job(k);                        // 값은 기본 방식
    j.src   = mem_base + k * 32'h0010_0000;         // 원본: 창 시작 (4KB 정렬)
    j.dst   = j.src + 32'h0008_0000;                // 대상: 창의 512KB 지점 (4KB 정렬)
    j.bytes = beats * BEAT;                         // 크기
    j.mode  = DONE_IRQ;                             // GIE=1, IER=1 (ap_done)
    return j;                                       // job
  endfunction                                       // place 끝

  // 단계를 모두 끈 dma_job_vseq (부른 쪽이 필요한 단계만 켬). 완료 대기는 인터럽트, AP_CTRL은 RD_DELAY 뒤, idle 재확인 없음
  function dma_job_vseq stage(dma_job j);           // job
    dma_job_vseq s = dma_job_vseq::type_id::create("stage_vseq");  // vseq
    s.job             = j;                          // job
    s.do_prep         = 0;                          // 메모리 안 씀
    s.do_program      = 0;                          // 레지스터 안 씀
    s.do_start        = 0;                          // start 안 씀
    s.do_wait         = 0;                          // 기다리지 않음
    s.done_wait       = dma_job_vseq::IRQ;          // 완료는 인터럽트로
    s.ctrl_rd_delay   = RD_DELAY;                   // ISR 읽기 뒤 AP_CTRL까지
    s.wait_idle_after = 0;                          // 완료 뒤 idle polling 안 함 (AP_CTRL 읽기를 늘리지 않음)
    return s;                                       // vseq
  endfunction                                       // stage 끝

  // 메모리, 레지스터, (idle_first) idle 확인, start. with_wait면 완료 대기까지
  task start_regs(dma_job j, bit idle_first, bit with_wait = 0);  // job, idle 확인, 완료 대기
    dma_job_vseq s = stage(j);                      // vseq
    s.do_prep          = 1;                         // 메모리
    s.do_program       = 1;                         // 레지스터
    s.do_start         = 1;                         // start
    s.wait_idle_before = idle_first;                // idle 확인
    s.do_wait          = with_wait;                 // 완료 대기
    s.start(env.vsqr);                              // 실행
  endtask                                           // start_regs 끝

  task wait_done(dma_job j);                        // 완료 대기만 (인터럽트 -> ISR -> RD_DELAY -> AP_CTRL)
    dma_job_vseq s = stage(j);                      // vseq
    s.do_wait = 1;                                  // 완료 대기
    s.start(env.vsqr);                              // 실행 (끝나거나 JOB_TIMEOUT까지)
  endtask                                           // wait_done 끝

  task do_reset(string tag);                        // 테스트 중간 리셋 (tag: 단계)
    dma_reset_vseq rs = dma_reset_vseq::type_id::create("reset_vseq");  // 리셋 vseq (n_cycles 기본 16)
    int unsigned   n0 = n_rst;                      // 리셋 수
    rs.start(env.vsqr);                             // 리셋
    if (n_rst != n0 + 1)                            // 리셋을 못 봄
      `uvm_error("SCENARIO_MISS", $sformatf("%s: mid-test reset not seen (resets %0d -> %0d)", tag, n0, n_rst))  // 미도달
    `uvm_info("H1", $sformatf("%s: reset done, W beats without AW at reset=%0d", tag, orphan_w), UVM_LOW)  // 요약
  endtask                                           // do_reset 끝

  // R handshake 수가 n이 될 때까지 (MAX_WAIT클럭 안). ok = 닿았는지
  task wait_r(int unsigned n, output bit ok);       // 목표 수, 결과
    for (int unsigned i = 0; i < MAX_WAIT && r_t.size() < n; i++) env.clocks(1);  // 한 클럭씩
    ok = (r_t.size() >= n);                         // 닿았는지
  endtask                                           // wait_r 끝

  // ---- 버스 관찰 ----
  // m00: AR/R/B 시각, AW beat 합과 W beat 수 (매 에지, 값은 에지 직전 표본)
  task m00_watch();                                 // m00 관찰
    axi4_vif v = env.mem_agt.vif;                   // m00 interface
    forever begin                                   // 매 에지
      @(v.moncb);                                   // 다음 에지
      if (v.moncb.arvalid === 1'b1 && v.moncb.arready === 1'b1) ar_t.push_back($time);  // AR
      if (v.moncb.rvalid  === 1'b1 && v.moncb.rready  === 1'b1) r_t.push_back($time);   // R
      if (v.moncb.bvalid  === 1'b1 && v.moncb.bready  === 1'b1) b_t.push_back($time);   // B
      if (v.moncb.awvalid === 1'b1 && v.moncb.awready === 1'b1) bal_aw += v.moncb.awlen + 1;  // AW beat 합
      if (v.moncb.wvalid  === 1'b1 && v.moncb.wready  === 1'b1) bal_w++;                // W beat 수
    end                                             // forever 끝
  endtask                                           // m00_watch 끝

  // AXI-Lite: AP_CTRL 쓰기 (W handshake 에지. 주소는 앞선 AW handshake 주소 = DUT의 waddr)와 읽기 (AR 주소, R 데이터)
  task ctl_watch();                                 // AXI-Lite 관찰
    virtual axil_if v = env.ctl_vif;                // 제어 interface
    bit [11:0]      waddr, raddr;                   // 마지막 AW, AR 주소 ([5:0]만, DUT와 같음)
    time            t_ar;                           // 마지막 AR 시각
    forever begin                                   // 매 에지
      @(v.moncb);                                   // 다음 에지
      if (v.moncb.wvalid === 1'b1 && v.moncb.wready === 1'b1 && waddr == ADDR_AP_CTRL) begin  // AP_CTRL 쓰기
        wr_t.push_back($time);                      // 시각
        wr_d.push_back(v.moncb.wdata);              // 값
      end                                           // if 끝
      if (v.moncb.awvalid === 1'b1 && v.moncb.awready === 1'b1) waddr = v.moncb.awaddr & 12'h03F;  // AW 주소
      if (v.moncb.arvalid === 1'b1 && v.moncb.arready === 1'b1) begin  // AR
        raddr = v.moncb.araddr & 12'h03F;           // 주소
        t_ar  = $time;                              // 시각
      end                                           // if 끝
      if (v.moncb.rvalid === 1'b1 && v.moncb.rready === 1'b1 && raddr == ADDR_AP_CTRL) begin  // AP_CTRL 읽기
        rd_t.push_back(t_ar);                       // AR 시각
        rd_v.push_back(v.moncb.rdata);              // 읽은 값
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // ctl_watch 끝

  // 리셋: 시작 에지에서 AW 없이 남은 W beat 수를 남기고 셈을 다시 시작 (m00_watch는 같은 에지를 NBA 전에 이미 셈)
  task rst_watch();                                 // 리셋 관찰
    forever begin                                   // 리셋마다
      @(negedge env.ctl_vif.rst_n);                 // 리셋 시작
      n_rst++;                                      // 수 증가
      orphan_w = (bal_w > bal_aw) ? bal_w - bal_aw : 0;  // AW 없이 남은 W beat
      bal_w = 0; bal_aw = 0;                        // 다시 셈
    end                                             // forever 끝
  endtask                                           // rst_watch 끝

  // ---- 계산 도우미 ----
  function int unsigned bursts(dma_job j); return (j.beats() + BURST - 1) / BURST; endfunction  // 4KB 정렬 job의 burst 수

  function string where(dma_job j);                 // 로그용 위치와 크기 (job 번호는 vseq가 start 때 붙임)
    return $sformatf("src=0x%08h dst=0x%08h %0d beats", j.src, j.dst, j.beats());  // 문자열
  endfunction                                       // where 끝

  function int unsigned n_le(ref time q[$], input time t);  // 시각 순 큐 q에서 t 이하 항목 수
    int unsigned n = q.size();                      // 뒤에서부터
    while (n > 0 && q[n - 1] > t) n--;              // t보다 늦은 항목 빼기
    return n;                                       // 수
  endfunction                                       // n_le 끝

  function time last_start();                       // 마지막 start=1 AP_CTRL 쓰기 시각 (없으면 0)
    for (int i = wr_t.size() - 1; i >= 0; i--)      // 뒤에서부터
      if (wr_d[i][AP_START]) return wr_t[i];        // start 비트
    return 0;                                       // 없음
  endfunction                                       // last_start 끝

  function bit idle_before(time t, int unsigned i0);  // 시각 t 전 마지막 AP_CTRL 읽기(i0번째부터)가 idle=1인지
    for (int i = rd_v.size() - 1; i >= int'(i0); i--)  // 뒤에서부터
      if (rd_t[i] < t) return rd_v[i][AP_IDLE];     // t 전 마지막 읽기
    return 0;                                       // 읽기 없음
  endfunction                                       // idle_before 끝

  function string reads_since(int unsigned i0);     // i0번째부터 AP_CTRL 읽기 값과 AR 시각
    string s;                                       // 결과
    for (int unsigned i = i0; i < rd_v.size(); i++) s = {s, $sformatf(" 0x%0h@%0t", rd_v[i], rd_t[i])};  // 값@시각
    return s;                                       // 결과
  endfunction                                       // reads_since 끝
endclass                                            // 클래스 끝
