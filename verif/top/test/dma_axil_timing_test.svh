// dma_axil_timing_test : AXI-Lite master 타이밍을 바꿔도 검사가 맞는지 (PASS 테스트)
//   dma_predictor는 버스 handshake만 입력으로 받는 사이클 모델이므로 AW/W 순서, B/R READY 지연이 달라져도 맞아야 함
//   노브 (cfg.ctl_cfg = axil_cfg): 쓰기마다 AW/W 순서와 간격(같은 사이클 / AW 먼저 / W 먼저, 1..SKEW 에지),
//         B/R 응답마다 READY 지연 0..READY_DELAY 에지 (VALID를 본 뒤 올림). m00 slave는 중간 정도 backpressure
//   자극 (기존 sequence 재사용, 검사는 바꾸지 않음):
//     1. 리셋 값 읽기 10개 (RAL 내장 uvm_reg_hw_reset_seq) -> REG_RESET
//     2. 작업 중 레지스터 쓰기와 읽기 (dma_busy_reg_vseq): job A(A_BEATS beat, polling 설정으로 start)가 R beat BUSY_AT_R개를
//        받은 뒤 job B 값(VALUE 하위 8비트가 A와 다름 -> A의 뒤쪽 beat는 새 값, NOTE-002), GIE=1/IER=1, ISR, AP_CTRL=0을 쓰고
//        10개를 다시 읽음. A는 작업 중 켠 인터럽트로 완료 대기, 그다음 B (idle 확인 뒤 start, 인터럽트로 완료)
//     3. 랜덤 job n_jobs개 (dma_job_vseq: 레지스터 쓰기, idle polling, start, irq_pct%는 인터럽트 -> ISR 읽기 -> AP_CTRL 읽기,
//        나머지는 AP_CTRL done polling)
//   판정은 기존 검사: 읽기값과 interrupt 핀 -> dma_predictor, 버스와 메모리 -> dma_scoreboard, slave VALID 유지 -> axil_if SVA
//   노린 상황 (AXI-Lite 버스 관찰 watch_axil, 끝에 하나라도 0이면 SCENARIO_MISS):
//     W 먼저      : WVALID가 AWVALID보다 먼저 1로 보인 쓰기
//     AW 먼저     : AWVALID가 WVALID보다 먼저 1로 보인 쓰기
//     늦은 BREADY : BVALID=1, BREADY=0인 에지가 있었던 쓰기
//     늦은 RREADY : RVALID=1, RREADY=0인 에지가 있었던 읽기
//     작업 중 쓰기 : 2의 레지스터 쓰기 구간이 A의 R beat 0 < k < A_BEATS 안 (쓰기 시작과 다시 읽기 끝의 m00 R handshake 수로 확인)
//   +N_JOBS=<n> : 3의 랜덤 job 수
class dma_axil_timing_test extends dma_base_test;   // 기본 테스트 상속
  `uvm_component_utils(dma_axil_timing_test)        // factory 등록
  localparam int unsigned SKEW        = 3;          // AW/W 간격 최대 (에지)
  localparam int unsigned READY_DELAY = 4;          // BREADY/RREADY 지연 최대 (에지)
  localparam int unsigned A_BEATS     = 1024;       // 2의 job A 크기 (레지스터 20번 접근이 끝날 때까지 넉넉히 돌도록)
  localparam int unsigned BUSY_AT_R   = 16;         // A가 R beat를 이만큼 받으면 레지스터를 씀
  localparam int unsigned MAX_WAIT    = 100000;     // A의 R을 기다리는 최대 사이클

  // AXI-Lite 버스 관찰 (watch_axil)
  int unsigned n_wr, n_rd;                          // 끝난 쓰기 수(B handshake), 읽기 수(R handshake)
  int unsigned n_same, n_aw_first, n_w_first;       // AWVALID와 WVALID가 같은 에지 / AW 먼저 / W 먼저인 쓰기 수
  int unsigned n_b_late, n_r_late;                  // BVALID가 READY 없이 기다린 쓰기 수, RVALID가 READY 없이 기다린 읽기 수
  int unsigned max_skew, max_b_wait, max_r_wait;    // 본 AW/W 간격 최댓값, B/R VALID가 READY 없이 기다린 에지 수 최댓값
  int          busy_r0 = -1, busy_r1 = -1;          // 2의 레지스터 쓰기 시작 / 다시 읽기 끝에 A가 받은 R beat 수 (-1 = 2를 못 감)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 8; min_beats = 1; max_beats = 200; irq_pct = 50;  // 3의 랜덤 job 8개, 1..200 beat, 인터럽트 50%
    cfg.ctl_cfg.max_aw_w_skew   = SKEW;             // AW/W 순서와 간격
    cfg.ctl_cfg.max_ready_delay = READY_DELAY;      // BREADY/RREADY 지연
    cfg.slv_cfg.ar_ready_pct  = 70;                 // ARREADY 70% (m00 완료 시점이 job마다 달라지도록)
    cfg.slv_cfg.w_ready_pct   = 70;                 // WREADY 70%
    cfg.slv_cfg.r_gap_pct     = 20;                 // R beat 앞 빈 사이클 20%
    cfg.slv_cfg.max_r_latency = 10;                 // 첫 R beat 지연 최대 10사이클
    cfg.slv_cfg.max_b_latency = 10;                 // B 응답 지연 최대 10사이클
  endfunction                                       // configure 끝

  function void start_of_simulation_phase(uvm_phase phase);  // 시뮬레이션 시작 직전 단계
    super.start_of_simulation_phase(phase);         // 기본 설정 요약
    `uvm_info("AXIL_TIMING", {"AXI-Lite master ", cfg.ctl_cfg.convert2string()}, UVM_LOW)  // 노브 요약
  endfunction                                       // start_of_simulation_phase 끝

  virtual task run_jobs();                          // 1 -> 2 -> 3, 그다음 도달 확인
    uvm_report_server    svr = uvm_report_server::get_server();  // JOB_TIMEOUT 수를 볼 report server
    uvm_reg_hw_reset_seq rs;                        // 1의 리셋 값 sequence
    fork watch_axil(); join_none                    // 버스 관찰 시작 (테스트 끝까지)
    // 1. 리셋 값 읽기 10개
    rs = uvm_reg_hw_reset_seq::type_id::create("hw_reset_seq");  // 내장 리셋 값 sequence
    rs.model = env.regmodel;                        // 대상 블록
    rs.start(null);                                 // frontdoor 접근은 map의 sequencer(AXI4-Lite)로 감
    // 2. 작업 중 레지스터 쓰기와 읽기
    busy_phase();                                   // A, 작업 중 레지스터, B
    // 3. 랜덤 job
    for (int unsigned i = 0; i < n_jobs && svr.get_id_count("JOB_TIMEOUT") == 0; i++)  // JOB_TIMEOUT이면 멈춤 (DUT가 아직 돌 수 있음)
      run_job(make_job(i + 2));                     // 1MB 창 2부터 (0, 1은 2에서 씀)
    env.clocks(2);                                  // 마지막 접근이 watch_axil에 들어가도록
    check_scenarios();                              // 도달 확인
  endtask                                           // run_jobs 끝

  // 2: A start -> A R beat BUSY_AT_R개 -> 레지스터 10개(B 값) 쓰기와 다시 읽기 -> A 완료(인터럽트) -> B start(idle 확인 뒤)와 완료(인터럽트)
  task busy_phase();                                // 작업 중 레지스터
    dma_job           a, b;                         // A, B
    dma_job_vseq      va, wa, vb;                   // A start, A 완료 대기, B
    dma_busy_reg_vseq vr;                           // 작업 중 레지스터 쓰기와 읽기
    int unsigned      r0, waited;                   // A start 전 R 수, 기다린 사이클
    a = make_job(0);                                // A: 위치와 값은 기본 방식 (1MB 창 0)
    a.bytes = A_BEATS * BEAT;                       // 크기
    a.mode  = DONE_POLL;                            // start 때 GIE=0, IER=0 (인터럽트는 작업 중에 켬)
    b = make_job(1);                                // B: 1MB 창 1
    if (b.value[7:0] == a.value[7:0]) b.value[7:0] = ~a.value[7:0];  // 하위 8비트가 달라야 A의 뒤쪽 beat가 바뀜 (NOTE-002)
    b.mode  = DONE_IRQ;                             // GIE=1, IER=1을 A 중에 씀
    va = dma_job_vseq::type_id::create("busy_a");   // A: 메모리, 레지스터, start만
    va.job = a;  va.do_wait = 0;                    // 완료는 아래에서
    r0 = env.mem_agt.drv.n_rd_beats;                // A start 전 R 수 (그 전엔 m00가 조용함)
    va.start(env.vsqr);                             // 실행
    while (env.mem_agt.drv.n_rd_beats < r0 + BUSY_AT_R && waited < MAX_WAIT) begin  // A가 R beat를 받을 때까지
      env.clocks(1);                                // 한 클럭
      waited++;                                     // 수
    end                                             // while 끝 (못 받으면 아래 완료 대기가 JOB_TIMEOUT)
    vr = dma_busy_reg_vseq::type_id::create("busy_regs");  // 작업 중 레지스터 10개 (값은 B)
    vr.job = b;                                     // B 메모리와 레지스터
    busy_r0 = env.mem_agt.drv.n_rd_beats - r0;      // 쓰기 시작 때 A의 R 수 (VALUE 쓰기 때 k는 이 값 이상)
    vr.start(env.vsqr);                             // 실행
    busy_r1 = env.mem_agt.drv.n_rd_beats - r0;      // 다시 읽기가 끝났을 때 A의 R 수 (VALUE 쓰기 때 k는 이 값 이하)
    `uvm_info("AXIL_TIMING", $sformatf("job A (%0d beats): %0d R beats when the 10 register writes started, %0d when the read-back ended",  // 진행 로그
                                       A_BEATS, busy_r0, busy_r1), UVM_LOW)  // R 수
    wa = dma_job_vseq::type_id::create("busy_a_wait");  // A 완료 대기 (작업 중 켠 인터럽트 -> ISR 읽기 -> AP_CTRL 읽기 -> idle)
    wa.job = a;  wa.do_prep = 0;  wa.do_program = 0;  wa.do_start = 0;  // 대기만
    wa.done_wait = dma_job_vseq::IRQ;               // 인터럽트로
    wa.start(env.vsqr);                             // 실행
    if (wa.timed_out) return;                       // JOB_TIMEOUT이면 멈춤 (보고는 vseq가 함)
    vb = dma_job_vseq::type_id::create("busy_b");   // B: 레지스터는 A 중에 썼으므로 idle 확인 뒤 start만, 완료는 인터럽트
    vb.job = b;  vb.do_prep = 0;  vb.do_program = 0;  // start와 완료 대기
    vb.start(env.vsqr);                             // 실행
  endtask                                           // busy_phase 끝

  // AXI-Lite 버스를 매 에지 관찰 (값은 에지 직전 표본). 쓰기 하나 = 첫 AWVALID/WVALID부터 B handshake까지, 읽기 하나 = R handshake까지
  task watch_axil();                                // 버스 관찰
    axil_pkg::axil_vif v = env.ctl_vif;             // 제어 interface
    int unsigned       e;                           // 에지 번호
    int unsigned       e_aw, e_w;                   // 이번 쓰기에서 AWVALID, WVALID를 처음 본 에지 (0 = 아직)
    int unsigned       b_wait, r_wait;              // 이번 응답에서 VALID=1, READY=0인 에지 수
    forever begin                                   // 계속 반복
      @(v.moncb);                                   // 매 클럭 에지
      if (v.rst_n !== 1'b1) continue;               // 리셋 에지 (이 테스트에서는 전원 리셋뿐)
      e++;                                          // 에지 번호 (1부터)
      if (v.moncb.awvalid === 1'b1 && e_aw == 0) e_aw = e;  // 첫 AWVALID
      if (v.moncb.wvalid  === 1'b1 && e_w  == 0) e_w  = e;  // 첫 WVALID
      if (v.moncb.bvalid === 1'b1 && v.moncb.bready !== 1'b1) b_wait++;  // BVALID가 READY 없이 기다림
      if (v.moncb.rvalid === 1'b1 && v.moncb.rready !== 1'b1) r_wait++;  // RVALID가 READY 없이 기다림
      if (v.moncb.bvalid === 1'b1 && v.moncb.bready === 1'b1) begin  // B handshake = 쓰기 하나 끝
        int unsigned skew;                          // AW/W 간격 (에지)
        n_wr++;                                     // 수
        if      (e_w < e_aw) begin n_w_first++;  skew = e_aw - e_w; end  // W 먼저
        else if (e_aw < e_w) begin n_aw_first++; skew = e_w - e_aw; end  // AW 먼저
        else                 begin n_same++;     skew = 0;          end  // 같은 에지
        if (skew > max_skew) max_skew = skew;       // 최댓값
        if (b_wait > 0) n_b_late++;                 // 늦은 BREADY
        if (b_wait > max_b_wait) max_b_wait = b_wait;  // 최댓값
        e_aw = 0; e_w = 0; b_wait = 0;              // 다음 쓰기
      end                                           // if 끝
      if (v.moncb.rvalid === 1'b1 && v.moncb.rready === 1'b1) begin  // R handshake = 읽기 하나 끝
        n_rd++;                                     // 수
        if (r_wait > 0) n_r_late++;                 // 늦은 RREADY
        if (r_wait > max_r_wait) max_r_wait = r_wait;  // 최댓값
        r_wait = 0;                                 // 다음 읽기
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // watch_axil 끝

  // 노린 상황에 갔는지 (버스 관찰만 씀)
  function void check_scenarios();                  // 도달 확인
    string miss;                                    // 못 간 항목
    `uvm_info("AXIL_TIMING", $sformatf("bus: writes=%0d (same edge=%0d, AW first=%0d, W first=%0d, max skew=%0d) B late=%0d (max wait %0d) | reads=%0d R late=%0d (max wait %0d) | job A R beats during busy writes=[%0d,%0d] of %0d",  // 요약
                                       n_wr, n_same, n_aw_first, n_w_first, max_skew, n_b_late, max_b_wait,  // 쓰기
                                       n_rd, n_r_late, max_r_wait, busy_r0, busy_r1, A_BEATS), UVM_LOW)  // 읽기, 2
    if (n_w_first  == 0) miss = {miss, " no write with WVALID before AWVALID;"};  // W 먼저
    if (n_aw_first == 0) miss = {miss, " no write with AWVALID before WVALID;"};  // AW 먼저
    if (n_b_late   == 0) miss = {miss, " no write whose BVALID waited for BREADY;"};  // 늦은 BREADY
    if (n_r_late   == 0) miss = {miss, " no read whose RVALID waited for RREADY;"};  // 늦은 RREADY
    if (busy_r0 <= 0 || busy_r1 < 0 || busy_r1 >= int'(A_BEATS))  // 2의 쓰기가 A 도중(0 < k < A_BEATS)이 아니었음 (-1 = 2를 못 감)
      miss = {miss, $sformatf(" register writes during job A not shown (A R beats %0d..%0d, need 0 < k < %0d);", busy_r0, busy_r1, A_BEATS)};  // 작업 중 쓰기
    if (miss != "") `uvm_error("SCENARIO_MISS", {"AXI-Lite timing:", miss})  // 못 감
  endfunction                                       // check_scenarios 끝
endclass                                            // 클래스 끝
