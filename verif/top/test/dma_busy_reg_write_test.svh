// dma_busy_reg_write_test : 작업 중 레지스터 쓰기, H3(작업 중 VALUE_TO_ADD), idle 확인 없는 연속 작업, in-place (directed, PASS 테스트)
//   H3 (사용자 결정: RTL 동작을 문서화, NOTE-002): adder가 R handshake 사이클의 VALUE_TO_ADD를 잡으므로(axis_adder.v:99-109,
//       dma_ip_top.v:302) 작업 중에 바꾸면 그 뒤 R beat부터 새 값이 더해짐. dma_predictor가 VALUE W 에지까지 받은 R 수 k로
//       beat >= k의 기대값을 바꾸고([PRED_VALUE] 줄), scoreboard가 W beat마다 비교함. 검사는 바꾸지 않음
//   job 8개 (1MB 창 0..7, 리셋 없음). 짝수 번째 job(1부터 셈: 2, 4, 6, 8번째)은 in-place
//     1. 작업 중 레지스터 10개 (dma_busy_reg_vseq): job A(256 beat)가 R beat BUSY_AT_R개를 받은 뒤 job B 값으로 데이터 레지스터 6개,
//        GIE=1/IER=1, ISR(쓰기 무시), AP_CTRL=0x00을 쓰고 10개를 다시 읽음. VALUE는 A의 하위 8비트 그대로(위 24비트만 다름).
//        A는 PRE 시점 크기/주소로 끝나야 하고(scoreboard), 작업 중 켠 인터럽트로 완료를 기다림(IRQ). B는 A 중에 쓴 값으로 실행(dst<src)
//     2. dma_pipeline_vseq (value_at_r = V1_AT_R, r_gap_pct=50): J0 128 beat 0x11 -> J1 0x22 (dst=src) -> J2 0x11 (IRQ) ->
//        J3 0xABCDEF22 (dst<src). 다음 job의 VALUE를 지금 job R beat V1_AT_R개 근처에서 씀
//          V1 = J0 (0x11 -> 0x22, 0 < k < 128), V3 = J2 (0x11 -> 0xABCDEF22: 하위 8비트 0x22만 더해져야 함)
//     3. dma_pipeline_vseq (value_at_r = beat 수, r_gap 0, w_ready_pct=30, max_b_latency=40): J4 64 beat 0x11 -> J5 0x22 (dst=src)
//          V2 = J4: 마지막 R 뒤, W beat가 아직 남아 있을 때 VALUE를 씀 -> k = beat 수 (모두 옛 값)
//   in-place는 dst=src와 dst<src 겹침만 (dst>src 겹침은 아직 읽지 않은 src를 덮으므로 사양 밖)
//   시나리오 도달 (F8): m00와 AXI-Lite 버스를 매 에지 기록하고(bus_watch_*), 끝에 job마다(start 쓰기 시각으로 나눔) 확인.
//     job이 "도는 중" = 그 job 첫 AR 에지 이상, 마지막 B 에지 미만. 못 갔으면 SCENARIO_MISS:
//       - 레지스터 10개 각각: job이 도는 중에 쓰기가 있었는지
//       - V1/V3: VALUE 쓰기 에지까지 그 job R handshake 수 k가 0 < k < beat 수이고, 쓴 값이 계획한 값(하위 8비트가 바뀜)
//       - V2: k = beat 수이고 그때 W beat가 남아 있음
//       - in-place: 계획한 job마다 AR 범위와 AW 범위가 겹치고 종류(dst=src, dst<src)가 맞음
//       - idle 확인 없는 start: 계획한 job마다 start 쓰기 직전 AXI-Lite 읽기가 done=1인 AP_CTRL 읽기 (사이에 idle polling 없음)
//     k는 dma_predictor와 같은 정의 (VALUE W handshake 에지 이하 에지에서 그 job이 받은 R handshake 수). [H3] 줄에 남김
class dma_busy_reg_write_test extends dma_base_test;  // 기본 테스트 상속
  `uvm_component_utils(dma_busy_reg_write_test)     // factory 등록
  localparam int unsigned NJ        = 8;            // job 수 (A, B, J0..J5)
  localparam int unsigned IX_V1     = 2;            // V1 job (J0) 위치
  localparam int unsigned IX_V3     = 4;            // V3 job (J2) 위치
  localparam int unsigned IX_V2     = 6;            // V2 job (J4) 위치
  localparam int unsigned A_BEATS   = 256;          // job A 크기 (레지스터 20번 접근이 끝날 때까지 돌도록 넉넉히)
  localparam int unsigned BUSY_AT_R = 16;           // A가 R beat를 이만큼 받으면 레지스터를 씀
  localparam int unsigned V1_BEATS  = 128;          // V1 job 크기
  localparam int unsigned V1_AT_R   = 40;           // V1/V3: 다음 job VALUE를 쓰는 R handshake 수 (요청)
  localparam int unsigned V2_BEATS  = 64;           // V2 job 크기 (value_at_r도 이 값: 마지막 R 뒤)
  localparam int unsigned MAX_WAIT  = 100000;       // A의 R을 기다리는 최대 사이클
  localparam int          IP_NONE = 0, IP_SAME = 1, IP_BELOW = 2;  // in-place 계획: 없음, dst=src, dst<src 겹침

  dma_job      plan_q[$];                           // 실행 순서대로 job (끝의 확인용)
  int          ip_plan[NJ];                         // job별 in-place 계획 (IP_*)
  bit          no_idle_plan[NJ];                    // job별 idle 확인 없이 start하는 계획
  // 버스 기록 (m00): handshake 에지 시각, AR/AW 주소와 beat 수
  time         ar_t[$], aw_t[$], r_t[$], w_t[$], b_t[$];  // AR, AW, R, W, B handshake 시각
  bit [31:0]   ar_a[$], aw_a[$];                    // AR, AW 주소
  int unsigned ar_n[$], aw_n[$];                    // AR, AW beat 수
  // 버스 기록 (AXI-Lite): 쓰기는 AW와 W가 모두 끝난 에지(DUT가 레지스터를 바꾸는 에지), 읽기는 R 에지
  time         wr_t[$], rd_t[$];                    // 쓰기, 읽기 시각
  bit [11:0]   wr_a[$], rd_a[$];                    // 주소
  bit [31:0]   wr_d[$], rd_d[$];                    // 데이터
  time         s_t[$];                              // job별 start 쓰기(AP_CTRL[0]=1) 시각 (analyze가 채움)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = NJ; min_beats = 16; max_beats = A_BEATS;  // 로그용 (job 크기는 run_jobs가 정함)
    cfg.slv_cfg.r_gap_pct = 50;                     // R 사이 빈 사이클 50% (V1, 작업 중 쓰기 여유). 3단계에서 바꿈
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // 1 -> 2 -> 3, 그다음 도달 확인
    uvm_report_server svr = uvm_report_server::get_server();  // JOB_TIMEOUT 수를 볼 report server
    dma_job a, b;                                   // 1단계 job
    dma_job p1[$], p2[$];                           // 2, 3단계 job
    fork bus_watch_m00(); bus_watch_axil(); join_none  // 버스 기록 시작
    // 1. 작업 중 레지스터 10개
    a = new_job(0, A_BEATS, IP_NONE);               // A: 값은 기본 방식, polling으로 시작
    b = new_job(1, $urandom_range(64, 16), IP_BELOW);  // B: dst<src 겹침
    b.value = {~a.value[31:8], a.value[7:0]};       // A의 하위 8비트 그대로 (A 데이터는 그대로, 위 24비트만 다름)
    b.mode  = DONE_IRQ;                             // GIE=1, IER=1을 A 중에 씀
    busy_phase(a, b);                               // 실행
    if (svr.get_id_count("JOB_TIMEOUT") > 0) return;  // 끝나지 않은 job이 있으면 멈춤 (보고는 vseq가 함)
    // 2. V1, V3, in-place, idle 확인 없는 start (r_gap_pct=50)
    p1.push_back(new_job(2, V1_BEATS, IP_NONE));                 p1[0].value = 32'h11;  // J0 (V1)
    p1.push_back(new_job(3, $urandom_range(128, 64), IP_SAME));  p1[1].value = 32'h22;  // J1: dst=src
    p1.push_back(new_job(4, $urandom_range(128, 64), IP_NONE));  p1[2].value = 32'h11;  // J2 (V3)
    p1[2].mode = DONE_IRQ;                          // J2는 인터럽트로 (done 뒤 GIE/IER를 쓰고 start)
    p1.push_back(new_job(5, $urandom_range(128, 16), IP_BELOW)); p1[3].value = 32'hABCD_EF22;  // J3: dst<src
    no_idle_plan[3] = 1; no_idle_plan[4] = 1; no_idle_plan[5] = 1;  // J1..J3은 done 뒤 바로 start
    run_pipeline(p1, V1_AT_R);                      // 실행
    if (svr.get_id_count("JOB_TIMEOUT") > 0) return;  // 멈춤
    // 3. V2: R은 빠르게, W는 밀리게 (마지막 R 뒤에도 W beat가 남음)
    cfg.slv_cfg.r_gap_pct     = 0;                  // R 빈 사이클 없음
    cfg.slv_cfg.w_ready_pct   = 30;                 // WREADY 30%
    cfg.slv_cfg.max_b_latency = 40;                 // B 지연 0..40
    p2.push_back(new_job(6, V2_BEATS, IP_NONE));                 p2[0].value = 32'h11;  // J4 (V2)
    p2.push_back(new_job(7, $urandom_range(64, 16), IP_SAME));   p2[1].value = 32'h22;  // J5: dst=src
    no_idle_plan[7] = 1;                            // J5는 done 뒤 바로 start
    run_pipeline(p2, V2_BEATS);                     // 실행 (VALUE는 J4 마지막 R 뒤)
    if (svr.get_id_count("JOB_TIMEOUT") > 0) return;  // 멈춤
    analyze();                                      // 도달 확인
  endtask                                           // run_jobs 끝

  // job 하나 (1MB 창 idx, 값은 기본 방식, polling). ip: in-place 계획 (src를 창 시작에서 64KB 띄워 dst<src와 앞 guard가 창 안에 들게)
  function dma_job new_job(int unsigned idx, int unsigned beats, int ip);  // 순번(= 창), beat 수, in-place 계획
    dma_job j = make_job(idx);                      // 위치와 값
    j.bytes = beats * BEAT;                         // 크기
    j.mode  = DONE_POLL;                            // 완료 방식 (필요하면 run_jobs가 바꿈)
    if (ip != IP_NONE) begin                        // in-place
      j.src = j.src + 32'h0001_0000;                // 창 시작에서 64KB 띄움
      j.dst = (ip == IP_SAME) ? j.src : j.src - BEAT * $urandom_range(beats - 1, 1);  // dst=src 또는 1..beats-1 beat 앞 (겹침)
    end                                             // if 끝
    if (idx != plan_q.size())                       // 순번이 실행 순서와 다르면 (테스트 코드 오류)
      `uvm_fatal("TEST", $sformatf("new_job(%0d) called as job %0d", idx, plan_q.size()))  // 중단
    ip_plan[idx] = ip;                              // 계획 기록
    plan_q.push_back(j);                            // 실행 순서
    return j;                                       // job
  endfunction                                       // new_job 끝

  // 1: A start -> A R beat BUSY_AT_R개 -> 레지스터 10개(B 값)와 다시 읽기 -> A 완료(인터럽트) -> B start(idle 확인 뒤)와 완료(인터럽트)
  task busy_phase(dma_job a, dma_job b);            // A, B
    dma_job_vseq      va, wa, vb;                   // A start, A 완료 대기, B
    dma_busy_reg_vseq vr;                           // 작업 중 레지스터 쓰기
    int unsigned      r0, waited;                   // A start 전 R 수, 기다린 사이클
    va = dma_job_vseq::type_id::create("busy_a");   // A: 메모리, 레지스터, start만
    va.job = a;  va.do_wait = 0;                    // 완료는 아래에서
    r0 = r_t.size();                                // A start 전 R 수 (그 전엔 m00가 조용함)
    va.start(env.vsqr);                             // 실행
    while (r_t.size() < r0 + BUSY_AT_R && waited < MAX_WAIT) begin  // A가 R beat를 받을 때까지
      env.clocks(1);                                // 한 클럭
      waited++;                                     // 수
    end                                             // while 끝 (못 받으면 아래 완료 대기가 JOB_TIMEOUT)
    vr = dma_busy_reg_vseq::type_id::create("busy_regs");  // 작업 중 레지스터 10개 (값은 B)
    vr.job = b;                                     // B 메모리와 레지스터
    vr.start(env.vsqr);                             // 실행
    wa = dma_job_vseq::type_id::create("busy_a_wait");  // A 완료 대기 (작업 중 켠 인터럽트 -> ISR 읽기 -> AP_CTRL 읽기 -> idle)
    wa.job = a;  wa.do_prep = 0;  wa.do_program = 0;  wa.do_start = 0;  // 대기만
    wa.done_wait = dma_job_vseq::IRQ;               // 인터럽트로
    wa.start(env.vsqr);                             // 실행
    if (wa.timed_out) return;                       // JOB_TIMEOUT이면 멈춤
    vb = dma_job_vseq::type_id::create("busy_b");   // B: 레지스터는 A 중에 썼으므로 idle 확인 뒤 start만, 완료는 인터럽트
    vb.job = b;  vb.do_prep = 0;  vb.do_program = 0;  // start와 완료 대기
    vb.start(env.vsqr);                             // 실행
  endtask                                           // busy_phase 끝

  // 2, 3: dma_pipeline_vseq로 job들을 idle 확인 없이 잇달아 실행 (다음 job VALUE는 지금 job R handshake value_at_r개에서)
  task run_pipeline(dma_job jobs[$], int value_at_r);  // job들, VALUE 쓰기 R 수
    dma_pipeline_vseq p = dma_pipeline_vseq::type_id::create("pipe");  // pipeline vseq
    p.jobs       = jobs;                            // job들
    p.value_at_r = value_at_r;                      // VALUE 시점
    p.start(env.vsqr);                              // 실행 (마지막 job idle까지)
  endtask                                           // run_pipeline 끝

  // m00 버스를 매 에지 기록 (값은 에지 직전 표본)
  task bus_watch_m00();                             // m00 기록
    axi4_vif vif = env.mem_agt.vif;                 // m00 interface
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) begin  // AR handshake
        ar_t.push_back($time);  ar_a.push_back(vif.moncb.araddr);  ar_n.push_back(vif.moncb.arlen + 1);  // 시각, 주소, beat 수
      end                                           // if 끝
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) begin  // AW handshake
        aw_t.push_back($time);  aw_a.push_back(vif.moncb.awaddr);  aw_n.push_back(vif.moncb.awlen + 1);  // 시각, 주소, beat 수
      end                                           // if 끝
      if (vif.moncb.rvalid === 1'b1 && vif.moncb.rready === 1'b1) r_t.push_back($time);  // R handshake
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) w_t.push_back($time);  // W handshake
      if (vif.moncb.bvalid === 1'b1 && vif.moncb.bready === 1'b1) b_t.push_back($time);  // B handshake
    end                                             // forever 끝
  endtask                                           // bus_watch_m00 끝

  // AXI-Lite 버스를 매 에지 기록 (axil_monitor와 같은 짝짓기: AW와 W가 모두 끝난 에지에 쓰기, R 에지에 읽기)
  task bus_watch_axil();                            // AXI-Lite 기록
    virtual axil_if vif = env.ctl_vif;              // 제어 interface
    bit [11:0] aw_q[$], ar_q[$];                    // 짝을 기다리는 AW 주소, R을 기다리는 AR 주소
    bit [31:0] wd_q[$];                             // 짝을 기다리는 W 데이터
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) aw_q.push_back(vif.moncb.awaddr);  // AW handshake
      if (vif.moncb.wvalid  === 1'b1 && vif.moncb.wready  === 1'b1) wd_q.push_back(vif.moncb.wdata);   // W handshake
      while (aw_q.size() > 0 && wd_q.size() > 0) begin  // AW와 W가 모두 끝난 쓰기
        wr_t.push_back($time);  wr_a.push_back(aw_q.pop_front());  wr_d.push_back(wd_q.pop_front());  // 시각, 주소, 데이터
      end                                           // while 끝
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) ar_q.push_back(vif.moncb.araddr);  // AR handshake
      if (vif.moncb.rvalid === 1'b1 && vif.moncb.rready === 1'b1 && ar_q.size() > 0) begin  // R handshake
        rd_t.push_back($time);  rd_a.push_back(ar_q.pop_front());  rd_d.push_back(vif.moncb.rdata);  // 시각, 주소, 데이터
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // bus_watch_axil 끝

  // ---- 끝의 도달 확인 (버스 기록만 씀) ----
  function void analyze();                          // 모든 시나리오
    s_t.delete();                                   // job별 start 쓰기 시각
    foreach (wr_t[i]) if (wr_a[i] == ADDR_AP_CTRL && wr_d[i][AP_START]) s_t.push_back(wr_t[i]);  // start=1 쓰기
    if (s_t.size() != NJ)                           // job마다 start 하나가 아니면 (job 창을 나눌 수 없음)
      `uvm_error("SCENARIO_MISS", $sformatf("%0d start writes seen, expected %0d (one per job)", s_t.size(), NJ))  // 보고
    check_busy_regs();                              // 레지스터 10개
    check_value("V1", IX_V1, 32'h22, 0);            // V1: 0x11 -> 0x22, 0 < k < beat 수
    check_value("V3", IX_V3, 32'hABCD_EF22, 0);     // V3: 0x11 -> 0xABCDEF22, 0 < k < beat 수
    check_value("V2", IX_V2, 32'h22, 1);            // V2: 마지막 R 뒤, W 남음
    check_in_place();                               // in-place
    check_no_idle();                                // idle 확인 없는 start
  endfunction                                       // analyze 끝

  function time win_end(int unsigned j);            // job j 창 끝 = 다음 job start 쓰기 (마지막 job은 지금)
    return (j + 1 < s_t.size()) ? s_t[j + 1] : $time;  // 시각
  endfunction                                       // win_end 끝

  function time first_ar(int unsigned j);           // job j 창 안 첫 AR 에지 (없으면 0)
    foreach (ar_t[i]) if (ar_t[i] > s_t[j] && ar_t[i] <= win_end(j)) return ar_t[i];  // 첫 것
    return 0;                                       // 없음
  endfunction                                       // first_ar 끝

  function time last_b(int unsigned j);             // job j 창 안 마지막 B 에지 (없으면 창 끝)
    time lb = win_end(j);                           // 기본
    foreach (b_t[i]) if (b_t[i] > s_t[j] && b_t[i] <= win_end(j)) lb = b_t[i];  // 시각 순서라 마지막이 남음
    return lb;                                      // 시각
  endfunction                                       // last_b 끝

  function bit running(int unsigned j, time t);     // 에지 t에 job j가 도는 중인지 (첫 AR 이상, 마지막 B 미만)
    time fa = first_ar(j);                          // 첫 AR
    return fa != 0 && fa <= t && t < last_b(j);     // 구간 안
  endfunction                                       // running 끝

  function int unsigned n_in(time q[$], time lo, time hi);  // q에서 lo < t <= hi인 항목 수
    int unsigned n = 0;                             // 수
    foreach (q[i]) if (q[i] > lo && q[i] <= hi) n++;  // 구간 안
    return n;                                       // 수
  endfunction                                       // n_in 끝

  // 레지스터 10개 각각 job이 도는 중에 쓴 적이 있는지
  function void check_busy_regs();                  // 작업 중 쓰기
    int unsigned n[10];                             // 레지스터별(주소/4) 작업 중 쓰기 수
    string       s, miss;                           // 로그, 못 간 레지스터
    foreach (wr_t[i])                               // 쓰기마다
      for (int unsigned j = 0; j < s_t.size(); j++)  // 그때 도는 job이 있으면
        if (wr_a[i] <= ADDR_VALUE_TO_ADD && running(j, wr_t[i])) begin n[wr_a[i] / 4]++; break; end  // 셈
    foreach (n[r]) begin                            // 레지스터마다
      s = {s, $sformatf(" 0x%02h=%0d", r * 4, n[r])};  // 로그
      if (n[r] == 0) miss = {miss, $sformatf(" 0x%02h", r * 4)};  // 못 감
    end                                             // foreach 끝
    `uvm_info("BUSY", {"writes while a job was running, per register:", s}, UVM_LOW)  // 요약
    if (miss != "") `uvm_error("SCENARIO_MISS", {"no write while a job was running to register(s):", miss})  // 못 감
  endfunction                                       // check_busy_regs 끝

  // VALUE 쓰기 (H3): job ix가 도는 중의 VALUE 쓰기마다 k(그 에지 이하 R 수)와 W 수를 남기고, 노린 상태가 있었는지
  //   after_last_r=0: 값 want, 0 < k < beat 수 / after_last_r=1: 값 want, k = beat 수이고 W beat가 남음
  function void check_value(string tag, int unsigned ix, bit [31:0] want, bit after_last_r);  // 이름, job 위치, 값, V2인지
    dma_job      j;                                 // 그 job
    int unsigned k, nw, n_ok;                       // R 수, W 수, 맞는 쓰기 수
    bit [31:0]   old;                               // 쓰기 직전 값
    string       cond;                              // 노린 조건 (메시지용. ?:의 문자열 상수는 폭이 채워지므로 if)
    if (ix >= s_t.size()) return;                   // job이 없음 (analyze가 이미 보고)
    j   = plan_q[ix];                               // 계획한 job
    old = j.value;                                  // 처음 값
    foreach (wr_t[i]) begin                         // 쓰기마다
      if (wr_a[i] != ADDR_VALUE_TO_ADD || !running(ix, wr_t[i])) continue;  // 그 job 중 VALUE 쓰기만
      k  = n_in(r_t, s_t[ix], wr_t[i]);             // 그 에지 이하 R handshake 수
      nw = n_in(w_t, s_t[ix], wr_t[i]);             // 그 에지 이하 W handshake 수
      `uvm_info("H3", $sformatf("%s job#%0d (%0d beats): VALUE_TO_ADD 0x%08h -> 0x%08h written @%0t after k=%0d R beats (W beats so far=%0d): beats >= %0d use 0x%02h",  // 기록
                                tag, j.id, j.beats(), old, wr_d[i], wr_t[i], k, nw, k, wr_d[i][7:0]), UVM_LOW)  // 값들
      if (wr_d[i] == want && wr_d[i][7:0] != old[7:0] &&  // 계획한 값이고 하위 8비트가 바뀜
          (after_last_r ? (k == j.beats() && nw < j.beats()) : (k > 0 && k < j.beats())))  // k 조건
        n_ok++;                                     // 노린 상태
      old = wr_d[i];                                // 다음 쓰기의 직전 값
    end                                             // foreach 끝
    if (after_last_r) cond = "after its last R beat with W beats still pending";  // V2
    else              cond = "with 0 < k < beats";  // V1, V3
    if (n_ok == 0)                                  // 못 감
      `uvm_error("SCENARIO_MISS", $sformatf("%s: job#%0d had no VALUE_TO_ADD write of 0x%08h %s while it was running",  // 보고
                                            tag, j.id, want, cond))  // 조건
  endfunction                                       // check_value 끝

  // in-place: job마다 AR 범위와 AW 범위를 비교해 계획과 맞는지 (dst=src, dst<src 겹침, 겹침 없음)
  function void check_in_place();                   // in-place
    int unsigned n_same, n_below;                   // 본 dst=src, dst<src 겹침 job 수
    for (int unsigned j = 0; j < s_t.size() && j < NJ; j++) begin  // job마다
      longint unsigned rlo = '1, rhi = 0, wlo = '1, whi = 0;  // AR 범위, AW 범위 [lo, hi)
      int kind;                                     // 본 종류 (IP_*, 사양 밖 dst>src 겹침은 -1)
      foreach (ar_t[i]) if (ar_t[i] > s_t[j] && ar_t[i] <= win_end(j)) begin  // 창 안 AR
        if (ar_a[i] < rlo) rlo = ar_a[i];           // 시작
        if (ar_a[i] + ar_n[i] * BEAT > rhi) rhi = ar_a[i] + ar_n[i] * BEAT;  // 끝
      end                                           // foreach 끝
      foreach (aw_t[i]) if (aw_t[i] > s_t[j] && aw_t[i] <= win_end(j)) begin  // 창 안 AW
        if (aw_a[i] < wlo) wlo = aw_a[i];           // 시작
        if (aw_a[i] + aw_n[i] * BEAT > whi) whi = aw_a[i] + aw_n[i] * BEAT;  // 끝
      end                                           // foreach 끝
      if (!(wlo < rhi && rlo < whi)) kind = IP_NONE;  // 겹치지 않음
      else if (wlo == rlo)           kind = IP_SAME;  // dst=src
      else if (wlo < rlo)            kind = IP_BELOW; // dst<src 겹침
      else                           kind = -1;       // dst>src 겹침 (사양 밖, 계획하지 않음)
      if (kind == IP_SAME)  n_same++;               // 수
      if (kind == IP_BELOW) n_below++;              // 수
      if (kind != IP_NONE || ip_plan[j] != IP_NONE) // in-place job만 로그
        `uvm_info("BUSY", $sformatf("job#%0d in-place: AR [0x%08h,0x%08h) AW [0x%08h,0x%08h) -> %s (planned %s)", plan_q[j].id,  // 기록
                                    rlo, rhi, wlo, whi, ip_name(kind), ip_name(ip_plan[j])), UVM_LOW)  // 값들
      if (kind != ip_plan[j])                       // 계획과 다르면
        `uvm_error("SCENARIO_MISS", $sformatf("job#%0d: bus shows %s, planned %s", plan_q[j].id, ip_name(kind), ip_name(ip_plan[j])))  // 보고
    end                                             // for 끝
    `uvm_info("BUSY", $sformatf("in-place jobs seen on the bus: dst=src %0d, dst<src overlap %0d", n_same, n_below), UVM_LOW)  // 요약
  endfunction                                       // check_in_place 끝

  function string ip_name(int kind);                // in-place 종류 이름
    case (kind)                                     // 종류마다
      IP_NONE:  return "no overlap";                // 겹침 없음
      IP_SAME:  return "dst=src";                   // 같은 위치
      IP_BELOW: return "dst<src overlap";           // dst가 앞
      default:  return "dst>src overlap";           // 사양 밖
    endcase                                         // case 끝
  endfunction                                       // ip_name 끝

  // idle 확인 없는 start: start 쓰기 직전 AXI-Lite 읽기가 done=1인 AP_CTRL 읽기면 done을 본 뒤 idle polling 없이 start한 것
  function void check_no_idle();                    // 연속 작업
    int unsigned n_ok;                              // idle 확인 없이 start한 job 수
    for (int unsigned j = 1; j < s_t.size() && j < NJ; j++) begin  // 두 번째 job부터
      int    last = -1;                             // start 직전 읽기 위치
      bit    ok;                                    // idle 확인 없음
      string rs = "none";                           // 직전 읽기 (로그)
      foreach (rd_t[i]) if (rd_t[i] < s_t[j]) last = i;  // 시각 순서라 마지막이 남음
      ok = last >= 0 && rd_a[last] == ADDR_AP_CTRL && rd_d[last][AP_DONE];  // done을 본 AP_CTRL 읽기
      if (ok) n_ok++;                               // 수
      if (last >= 0) rs = $sformatf("0x%02h=0x%08h @%0t", rd_a[last], rd_d[last], rd_t[last]);  // 직전 읽기
      if (no_idle_plan[j] || ok)                    // 계획했거나 그렇게 된 job만 로그
        `uvm_info("BUSY", $sformatf("job#%0d start @%0t: previous job last B @%0t, last read before start: %s",  // 기록
                                    plan_q[j].id, s_t[j], last_b(j - 1), rs), UVM_LOW)  // 시각, 읽기
      if (no_idle_plan[j] && !ok)                   // 계획했는데 아님
        `uvm_error("SCENARIO_MISS", $sformatf("job#%0d: started after an idle check (last read before start is not an AP_CTRL read with done=1)", plan_q[j].id))  // 보고
    end                                             // for 끝
    `uvm_info("BUSY", $sformatf("jobs started right after done without an idle check: %0d", n_ok), UVM_LOW)  // 요약
  endfunction                                       // check_no_idle 끝
endclass                                            // 클래스 끝
