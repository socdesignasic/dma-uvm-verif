// dma_auto_restart_test : H2 가설 확인용 directed test (사양 검사 -> 가설이 맞으면 FAIL)
//   H2: AP_CTRL=0x81이면 int_auto_restart=1(control.v:362). ap_ready에서 int_ap_start <= int_auto_restart = 1(control.v:311)이라
//       start가 1로 남지만, wrapper는 상승 에지 펄스로만 넘기므로(wrapper.v:138) 두 번째 실행이 없음. done은 auto_restart_done
//       경로(control.v:282, 284)로 한 번. 그 뒤 0x00(auto_restart 끔)도 0x01도 int_ap_start=1이 남아 에지가 없음 -> 리셋 전까지 멈춤
//   사양 (HLS ap_ctrl_hs): auto_restart=1이면 끝날 때마다 같은 레지스터 값으로 다시 시작, 끄면 남은 반복 뒤 idle에서 멈춤,
//       idle에서 쓴 start는 실행. 기대는 dma_predictor의 블록 start 모델 (auto_restart 식은 control.v 그대로, 다시 시작 사이클은 TB 정의)
//   판정은 기존 검사: predictor(REG_STATUS, IRQ), scoreboard, APCTRL_SVA(a_ap_idle_leave), JOB_TIMEOUT. 검사를 바꾸지 않음
//   단계 (job E: 32 beat, 4KB 정렬(16 beat burst), GIE=1, IER=1):
//     a : 메모리, 레지스터, idle 확인, AP_CTRL=0x81 -> 인터럽트 N_IRQ번 기다림 (매번 ISR 읽기)
//         -> WIN클럭 관찰 (AR만 셈, AP_CTRL 읽기 없음. 창 안 AR이 없으면 JOB_TIMEOUT)
//         -> m00가 조용할 때만 AP_CTRL 2번 읽기 (quiet_read: 0x87, 0x85 증거)
//     b : 인터럽트 2번 기다림 (ISR_LOOP: 첫째는 창 동안 남은 인터럽트일 수 있어 지우기만, 둘째에서 위상을 잡음)
//         -> ISR 읽기 -> RD_DELAY -> AP_CTRL 읽기 -> 바로 AP_CTRL=0x00 (auto_restart 끔)
//         -> WIN클럭 관찰 (POLL클럭마다 AP_CTRL 읽기, AR 요구 없음. idle은 predictor가 비교)
//     c : SW 절차: idle 확인 -> AP_CTRL=0x01 -> WIN클럭 관찰 (POLL클럭마다 AP_CTRL 읽기, 창 안 AR이 없으면 JOB_TIMEOUT)
//     d : 리셋 -> 일반 job F(32 beat). PASS해야 함
//   AP_CTRL 읽기와 0x00 쓰기는 다시 시작 사건에서 먼 위상에서만 함: predictor의 다시 시작 사이클(IDLE 진입 +2)은 TB 정의라,
//   반복 중 임의 위상에서 읽거나 쓰면 RTL을 level 방식으로 고쳤을 때 ±1사이클 차이로 REG_STATUS가 나거나 한 번 더 실행할지가
//   달라짐 (고쳐진 RTL에서 XPASS가 확실히 나오게 함)
//     - ISR 읽기 뒤 AP_CTRL은 ctrl_rd_delay = RD_DELAY 뒤 (다음 실행은 이미 ap_ready를 지나 도는 중, 끝나기 전)
//     - 0x00은 그 AP_CTRL 읽기 바로 뒤 (그 실행의 ap_ready 뒤, 끝나기 전 -> 사양상 한 번 더 실행하고 idle)
//     - 0x87/0x85 증거 읽기는 m00가 RD_DELAY클럭 이상 조용할 때만 (QUIET_MAX클럭 안에 안 되면 읽지 않음).
//       지금 RTL은 멈춰 있어 바로 읽히고, 고쳐진 RTL은 쉬지 않고 다시 시작하므로 읽지 않음
//     - b, c 관찰 창의 읽기는 POLL클럭마다: 그때는 다시 시작이 이미 끝나 idle (32 beat 실행은 POLL보다 훨씬 짧음)
//   버스 관찰 (m00_watch, ctl_watch, rst_watch): m00 AR/B handshake 시각, AP_CTRL 쓰기와 읽기 값, interrupt 상승 수, 리셋.
//     노린 상태에 못 가면 SCENARIO_MISS:
//       a : 0x81 쓰기를 봄, 그 뒤 E 첫 실행이 끝남 (B 수 >= burst 수)   b : 0x00 쓰기를 봄
//       c : 0x01 쓰기를 봄, 그 직전 AP_CTRL 읽기가 idle=1              d : 리셋을 봄
//   [H2] 줄: 0x81 뒤 실행 수(AR 수 / burst 수), interrupt 수, AP_CTRL 읽기 값
class dma_auto_restart_test extends dma_base_test;  // 기본 테스트 상속
  `uvm_component_utils(dma_auto_restart_test)       // factory 등록
  localparam int unsigned RD_DELAY = 16;            // ISR 읽기 뒤 AP_CTRL 읽기까지 클럭 (ctrl_rd_delay)
  localparam int unsigned BURST    = 16;            // 4KB 정렬 job의 burst 길이 (beat)
  localparam int unsigned N_IRQ    = 3;             // 단계 a에서 기다릴 인터럽트 수 (반복 3번)
  localparam int unsigned WIN      = 2000;          // 관찰 창 (클럭)
  localparam int unsigned POLL     = 500;           // 창 안 AP_CTRL 읽기 간격 (클럭, RD_DELAY 이상)
  localparam int unsigned QUIET_MAX = WIN;          // quiet_read가 m00가 조용해지기를 기다리는 최대 클럭
  localparam bit [31:0]   CTRL_AUTO_START = (32'h1 << AP_AUTO_RESTART) | (32'h1 << AP_START);  // 0x81
  localparam bit [31:0]   CTRL_START      = 32'h1 << AP_START;  // 0x01

  // 버스 관찰 결과
  time         ar_t[$], b_t[$];                     // m00 AR, B handshake 시각
  time         wr_t[$];                             // AP_CTRL 쓰기 W handshake 시각
  bit [31:0]   wr_d[$];                             // 그 값
  time         rd_t[$];                             // AP_CTRL 읽기 AR 시각
  bit [31:0]   rd_v[$];                             // 읽은 값
  int unsigned n_irq_rise;                          // interrupt 상승 수
  int unsigned n_rst;                               // 본 테스트 중간 리셋 수
  int unsigned quiet;                               // m00 5채널 VALID가 모두 0인 연속 에지 수

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual task run_jobs();                          // 단계 a -> b -> c -> d
    dma_job      e = place(0, 32), f = place(1, 32);  // E(32), F(32)
    dma_job_vseq s;                                 // 단계 vseq
    int unsigned ar0, b0, i0, q0, n_run;            // 기준 AR, B, AP_CTRL 읽기, interrupt 수, 0x81 뒤 B 수
    time         ta, tb, tc;                        // 0x81, 0x00, 0x01 쓰기 시각
    fork m00_watch(); ctl_watch(); rst_watch(); join_none  // 버스 관찰 시작
    ar0 = ar_t.size(); b0 = b_t.size(); i0 = rd_v.size(); q0 = n_irq_rise;  // 기준 (버스가 조용한 때)
    `uvm_info("H2", $sformatf("E src=0x%08h dst=0x%08h %0d beats | F src=0x%08h dst=0x%08h %0d beats",  // 시작 로그 (job 번호는 [JOB] 줄)
                              e.src, e.dst, e.beats(), f.src, f.dst, f.beats()), UVM_LOW)  // 값들
    // a: auto_restart와 함께 start, 인터럽트 N_IRQ번
    s = stage(e);                                   // vseq
    s.do_prep = 1; s.do_program = 1;                // 메모리, 레지스터
    s.do_start = 1; s.wait_idle_before = 1; s.start_value = CTRL_AUTO_START;  // idle 확인, 0x81
    s.do_wait = 1; s.done_wait = dma_job_vseq::ISR_LOOP; s.n_irq = N_IRQ;  // 인터럽트 N_IRQ번 (가설이 맞으면 JOB_TIMEOUT)
    s.start(env.vsqr);                              // 실행
    ta = last_write(CTRL_AUTO_START);               // 0x81 쓰기
    n_run = (ta == 0) ? 0 : b_t.size() - n_le(b_t, ta);  // 그 뒤 B 수
    `uvm_info("H2", $sformatf("a: 0x81 written @%0t: AR=%0d B=%0d (%0d bursts per run) interrupts=%0d",  // 도달 로그
                              ta, ar_t.size() - ar0, b_t.size() - b0, bursts(e), n_irq_rise - q0), UVM_LOW)  // 값들
    if (ta == 0)                                    // 0x81을 못 봄
      `uvm_error("SCENARIO_MISS", "a: AP_CTRL=0x81 write not seen")  // 미도달
    else if (n_run < bursts(e))                     // 첫 실행이 끝나지 않음
      `uvm_error("SCENARIO_MISS", $sformatf("a: first run after 0x81 did not finish (B=%0d/%0d)", n_run, bursts(e)))  // 다시 시작할 IDLE에 못 감
    window(e, 1, 0);                                // 관찰: auto_restart면 AR이 있어야 함 (AR만 셈, 읽기 없음)
    quiet_read(e, "a");                             // 0x87 증거 (m00가 조용할 때만)
    quiet_read(e, "a");                             // 0x85 증거 (m00가 조용할 때만)
    // b: 정해진 위상에서 auto_restart 끔 (인터럽트 -> ISR 읽기 -> RD_DELAY -> AP_CTRL 읽기 -> 0x00)
    s = stage(e);                                   // vseq
    s.do_wait = 1; s.done_wait = dma_job_vseq::ISR_LOOP; s.n_irq = 2;  // 첫째는 남은 인터럽트 지우기, 둘째(새 완료)에서 위상 (가설이 맞으면 JOB_TIMEOUT)
    s.start(env.vsqr);                              // 실행
    s = stage(e);                                   // vseq
    s.do_start = 1; s.wait_idle_before = 0; s.start_value = 32'h0;  // 바로 0x00 (idle 확인 없이)
    s.start(env.vsqr);                              // 실행
    tb = last_write(32'h0);                         // 0x00 쓰기
    if (tb <= ta)                                   // 못 봄
      `uvm_error("SCENARIO_MISS", "b: AP_CTRL=0x00 write not seen")  // 미도달
    else                                            // 위상 확인용 (고쳐진 RTL이면 마지막 B 뒤 새 실행의 AR이 이미 있어야 함)
      `uvm_info("H2", $sformatf("b: 0x00 written @%0t: last AR @%0t, last B @%0t", tb,  // 위상 로그
                                (ar_t.size() > 0) ? ar_t[ar_t.size() - 1] : 0, (b_t.size() > 0) ? b_t[b_t.size() - 1] : 0), UVM_LOW)  // 값들
    window(e, 0, POLL);                             // 관찰 (AR 요구 없음, POLL클럭마다 읽기)
    // c: SW 절차로 start
    s = stage(e);                                   // vseq
    s.do_start = 1; s.wait_idle_before = 1; s.start_value = CTRL_START;  // idle 확인, 0x01
    s.start(env.vsqr);                              // 실행
    tc = last_write(CTRL_START);                    // 0x01 쓰기
    if (tc <= tb)                                   // 못 봄
      `uvm_error("SCENARIO_MISS", "c: AP_CTRL=0x01 write not seen")  // 미도달
    else if (!idle_before(tc, i0))                  // 직전 읽기가 idle=1이 아님
      `uvm_error("SCENARIO_MISS", $sformatf("c: 0x01 @%0t not after an AP_CTRL read with idle=1", tc))  // SW 절차가 아님
    window(e, 1, POLL);                             // 관찰: idle에서 쓴 start면 AR이 있어야 함 (POLL클럭마다 읽기)
    `uvm_info("H2", $sformatf("a-c: runs after 0x81=%0d (AR=%0d, %0d per run) interrupts=%0d | AR after 0x00 @%0t=%0d, after 0x01 @%0t=%0d | AP_CTRL reads:%s",  // 요약
                              (ar_t.size() - ar0) / bursts(e), ar_t.size() - ar0, bursts(e), n_irq_rise - q0,  // 실행 수, interrupt
                              tb, ar_t.size() - n_le(ar_t, tb), tc, ar_t.size() - n_le(ar_t, tc), reads_since(i0)), UVM_LOW)  // AR, 읽기 값
    // d: 리셋 뒤 일반 job
    do_reset("d");                                  // 리셋
    b0 = b_t.size();                                // 기준
    run_job(f);                                     // 기본 순서 (idle 확인, start, 인터럽트 완료, idle 대기)
    `uvm_info("H2", $sformatf("d: F B=%0d/%0d", b_t.size() - b0, bursts(f)), UVM_LOW)  // 요약 (판정은 scoreboard SB_JOB)
  endtask                                           // run_jobs 끝

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

  // 단계를 모두 끈 dma_job_vseq (부른 쪽이 필요한 단계만 켬). AP_CTRL은 ISR 읽기 RD_DELAY 뒤, idle 재확인 없음
  function dma_job_vseq stage(dma_job j);           // job
    dma_job_vseq s = dma_job_vseq::type_id::create("stage_vseq");  // vseq
    s.job             = j;                          // job
    s.do_prep         = 0;                          // 메모리 안 씀
    s.do_program      = 0;                          // 레지스터 안 씀
    s.do_start        = 0;                          // start 안 씀
    s.do_wait         = 0;                          // 기다리지 않음
    s.ctrl_rd_delay   = RD_DELAY;                   // ISR 읽기 뒤 AP_CTRL까지
    s.wait_idle_after = 0;                          // 완료 뒤 idle polling 안 함
    return s;                                       // vseq
  endfunction                                       // stage 끝

  // WIN클럭 관찰: poll클럭마다 AP_CTRL 읽기 (0이면 읽지 않음), 창 안 AR handshake가 min_ar보다 적으면 JOB_TIMEOUT
  task window(dma_job j, int unsigned min_ar, int unsigned poll);  // job (메시지용), 최소 AR 수, 읽기 간격
    dma_job_vseq s = stage(j);                      // vseq
    s.do_wait       = 1;                            // 대기 단계
    s.done_wait     = dma_job_vseq::WINDOW;         // 관찰 창
    s.window_cycles = WIN;                          // 창 길이
    s.window_poll   = poll;                         // AP_CTRL 읽기 간격
    s.window_min_ar = min_ar;                       // 최소 AR 수
    s.start(env.vsqr);                              // 실행
  endtask                                           // window 끝

  // m00가 RD_DELAY클럭 이상 조용할 때(5채널 VALID 모두 0) AP_CTRL 한 번 읽기. QUIET_MAX클럭 안에 조용해지지 않으면 읽지 않음
  //   (고쳐진 RTL은 auto_restart로 쉬지 않고 다시 시작하므로 읽지 않는 것이 정상 -> 오류 아님, 로그만)
  //   읽기 하나는 WINDOW 2클럭, 간격 1클럭으로 냄 (1클럭 뒤 읽기 시작, 창은 그 읽기 도중 끝나 한 번만 읽음, AR 요구 없음)
  task quiet_read(dma_job j, string tag);           // job (이미 번호가 붙은 것, vseq용), 단계
    dma_job_vseq s;                                 // 읽기 vseq
    for (int unsigned i = 0; i < QUIET_MAX && quiet < RD_DELAY; i++) env.clocks(1);  // 조용해질 때까지 (quiet는 한 에지 늦을 수 있어 실제보다 작게만 셈)
    if (quiet < RD_DELAY) begin                     // 조용해지지 않음
      `uvm_info("H2", $sformatf("%s: m00 never quiet for %0d cycles within %0d cycles, AP_CTRL not read", tag, RD_DELAY, QUIET_MAX), UVM_LOW)  // 정보
      return;                                       // 읽지 않음
    end                                             // if 끝
    s = stage(j);                                   // vseq (min_ar=0이라 job은 메시지에 쓰이지 않음)
    s.do_wait       = 1;                            // 대기 단계
    s.done_wait     = dma_job_vseq::WINDOW;         // 관찰 창
    s.window_cycles = 2;                            // 2클럭
    s.window_poll   = 1;                            // 1클럭 뒤 읽기
    s.window_min_ar = 0;                            // AR 요구 없음
    s.start(env.vsqr);                              // 실행
  endtask                                           // quiet_read 끝

  task do_reset(string tag);                        // 테스트 중간 리셋 (tag: 단계)
    dma_reset_vseq rs = dma_reset_vseq::type_id::create("reset_vseq");  // 리셋 vseq (n_cycles 기본 16)
    int unsigned   n0 = n_rst;                      // 리셋 수
    rs.start(env.vsqr);                             // 리셋
    if (n_rst != n0 + 1)                            // 리셋을 못 봄
      `uvm_error("SCENARIO_MISS", $sformatf("%s: mid-test reset not seen (resets %0d -> %0d)", tag, n0, n_rst))  // 미도달
    `uvm_info("H2", $sformatf("%s: reset done", tag), UVM_LOW)  // 진행 로그
  endtask                                           // do_reset 끝

  // ---- 버스 관찰 ----
  // m00: AR/B 시각, VALID가 모두 0인 연속 에지 수 (매 에지, 값은 에지 직전 표본)
  task m00_watch();                                 // m00 관찰
    axi4_vif v = env.mem_agt.vif;                   // m00 interface
    forever begin                                   // 매 에지
      @(v.moncb);                                   // 다음 에지
      if (v.moncb.arvalid === 1'b1 && v.moncb.arready === 1'b1) ar_t.push_back($time);  // AR
      if (v.moncb.bvalid  === 1'b1 && v.moncb.bready  === 1'b1) b_t.push_back($time);   // B
      if (v.moncb.arvalid !== 1'b0 || v.moncb.rvalid !== 1'b0 || v.moncb.awvalid !== 1'b0 ||  // 어느 채널이든 VALID(또는 X)면
          v.moncb.wvalid  !== 1'b0 || v.moncb.bvalid !== 1'b0) quiet = 0;  // 다시 셈
      else quiet++;                                 // 조용한 에지
    end                                             // forever 끝
  endtask                                           // m00_watch 끝

  // AXI-Lite: AP_CTRL 쓰기 (W handshake 에지. 주소는 앞선 AW handshake 주소 = DUT의 waddr), 읽기 (AR 주소, R 데이터), interrupt 상승
  task ctl_watch();                                 // AXI-Lite 관찰
    virtual axil_if v = env.ctl_vif;                // 제어 interface
    bit [11:0]      waddr, raddr;                   // 마지막 AW, AR 주소 ([5:0]만, DUT와 같음)
    time            t_ar;                           // 마지막 AR 시각
    bit             irq, irq_q;                     // 이번, 지난 에지의 interrupt
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
      irq = (v.moncb.interrupt === 1'b1);           // interrupt
      if (irq && !irq_q) n_irq_rise++;              // 상승
      irq_q = irq;                                  // 다음 에지용
    end                                             // forever 끝
  endtask                                           // ctl_watch 끝

  task rst_watch();                                 // 리셋 관찰
    forever begin                                   // 리셋마다
      @(negedge env.ctl_vif.rst_n);                 // 리셋 시작
      n_rst++;                                      // 수 증가
    end                                             // forever 끝
  endtask                                           // rst_watch 끝

  // ---- 계산 도우미 ----
  function int unsigned bursts(dma_job j); return (j.beats() + BURST - 1) / BURST; endfunction  // 4KB 정렬 job의 burst 수

  function int unsigned n_le(ref time q[$], input time t);  // 시각 순 큐 q에서 t 이하 항목 수
    int unsigned n = q.size();                      // 뒤에서부터
    while (n > 0 && q[n - 1] > t) n--;              // t보다 늦은 항목 빼기
    return n;                                       // 수
  endfunction                                       // n_le 끝

  function time last_write(bit [31:0] d);           // 마지막 AP_CTRL 쓰기가 값 d이면 그 시각 (아니면 0)
    if (wr_d.size() == 0 || wr_d[wr_d.size() - 1] != d) return 0;  // 없거나 다른 값
    return wr_t[wr_t.size() - 1];                   // 시각
  endfunction                                       // last_write 끝

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
