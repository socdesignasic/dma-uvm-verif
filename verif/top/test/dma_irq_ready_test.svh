// dma_irq_ready_test : IER = ready만(2'b10) / ready와 done(2'b11) x GIE 0/1 조합으로 job을 여러 개 돌림 (PASS 테스트)
//   RTL (dma_ip_control_s_axi.v): ISR[1] <= IER[1] && ap_ready (:416, GIE와 무관), ISR 읽기로 지워짐 (:418)
//        AP_CTRL.ready <= task_ap_ready (:350), AP_CTRL 읽기로 지워짐 (:352), interrupt <= GIE && |ISR (:296)
//   조합마다 완료 대기 (dma_job_vseq 노브 gie, ier, done_wait, n_irq):
//     IER=11 GIE=1 : ISR_LOOP n_irq=2. ready 인터럽트 -> ISR 읽기 -> done 인터럽트 -> ISR 읽기 -> AP_CTRL 읽기
//     IER=10 GIE=1 : IRQ (ready 인터럽트 -> ISR 읽기 -> AP_CTRL 읽기), 그다음 같은 job을 POLL_DONE으로 완료 대기
//     IER=1x GIE=0 : POLL_DONE (interrupt는 내내 0이어야 함). 그다음 남은 ISR을 읽으려고 같은 레지스터 값에 GIE만 1로 바꿔
//                    다시 씀 (start 없음) -> 남은 ISR이 interrupt를 올림 -> IRQ (ISR 읽기 -> AP_CTRL 읽기)
//                    (dma_job_vseq는 interrupt를 기다려서만 ISR을 읽음)
//     어느 조합이든 job이 끝나면 ISR = 0, interrupt = 0 (다음 job이 앞 job의 인터럽트를 보지 않음)
//   읽기값과 interrupt 핀이 맞는지는 dma_predictor가 비교 (ISR[1], ready, interrupt[9] -> REG_STATUS / ISR[0], done, 핀 -> IRQ)
//   이 테스트는 노린 상태에 갔는지만 버스 관찰(axil_monitor의 접근, interrupt 핀, m00 W handshake)로 확인하고,
//   못 갔으면 SCENARIO_MISS:
//     job마다 - start 쓰기 때 버스에 마지막으로 쓴 IER/GIE가 그 조합 (start 쓰기는 한 번)
//             - ISR[1]=1인 ISR 읽기, ready=1인 AP_CTRL 읽기, (IER=11) ISR[0]=1인 ISR 읽기
//             - (GIE=1) 그 job의 마지막 m00 W beat 전에 올라간 interrupt (= ready 인터럽트)
//             - (IER=11 GIE=1) 완료 대기 중 interrupt 상승 2번 이상 (ready, done)
//     끝에    - 조합 4개가 모두 위를 만족한 job이 하나 이상
//   job 크기는 32 beat 이상: ready 인터럽트 뒤 ISR 읽기와 AP_CTRL 읽기(15사이클쯤)가 done보다 먼저 끝나야 함
//   (아니면 ISR_LOOP는 두 번째 인터럽트를, POLL_DONE은 done을 보지 못해 JOB_TIMEOUT)
//   +N_JOBS=<n> : job 수 (기본 8 = 조합마다 2개, 순서는 seed마다 섞음)
class dma_irq_ready_test extends dma_base_test;     // 기본 테스트 상속
  `uvm_component_utils(dma_irq_ready_test)          // factory 등록

  uvm_tlm_analysis_fifo #(axil_pkg::axil_item) axil_fifo;  // axil_monitor가 본 접근 (버스 관찰)
  int unsigned cur;                                 // 지금 job 번호 (1부터, 0이면 job 전)
  bit          drain;                               // 지금 job이 남은 ISR을 읽는 단계인지 (GIE=0 조합)
  bit          bus_gie;                             // 버스에 마지막으로 쓴 GIE[0]
  bit [1:0]    bus_ier;                             // 버스에 마지막으로 쓴 IER[1:0]
  // job별 값 (인덱스 = job 번호)
  bit          want_gie[];                          // 노린 GIE
  bit [1:0]    want_ier[];                          // 노린 IER
  int unsigned job_beats[];                         // beat 수
  int unsigned n_start[];                           // start=1 AP_CTRL 쓰기 수
  bit          start_gie[];                         // start 쓰기 때 버스의 GIE
  bit [1:0]    start_ier[];                         // start 쓰기 때 버스의 IER
  int unsigned n_isr_ready[];                       // ISR[1]=1인 ISR 읽기 수
  int unsigned n_isr_done[];                        // ISR[0]=1인 ISR 읽기 수
  int unsigned n_ready[];                           // ready=1인 AP_CTRL 읽기 수
  string       isr_values[];                        // 읽은 ISR 값 (로그용)
  int unsigned n_w[];                               // m00 W handshake 수
  int unsigned n_rise_wait[];                       // 완료 대기 중 interrupt 상승 수
  int unsigned n_rise_early[];                      // 그중 마지막 W beat 전 상승 수
  int unsigned n_rise_drain[];                      // 남은 ISR 읽기 단계의 interrupt 상승 수
  int unsigned combo_jobs[4];                       // 조합별 job 수 (조합 번호 c: IER = c[0] ? 11 : 10, GIE = c[1])
  int unsigned combo_hits[4];                       // 조합별 노린 상태에 간 job 수
  int unsigned n_isr_reads, n_rises;                // 전체 ISR 읽기 수, interrupt 상승 수 (요약용)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 8; min_beats = 32; max_beats = 200;    // job 8개 (조합마다 2개), 32..200 beat (32 미만이면 위 설명의 경합)
    cfg.slv_cfg.ar_ready_pct  = 70;                 // ARREADY 70% (완료 시점이 job마다 달라지도록 중간 정도 backpressure)
    cfg.slv_cfg.w_ready_pct   = 70;                 // WREADY 70%
    cfg.slv_cfg.r_gap_pct     = 20;                 // R beat 앞 빈 사이클 20%
    cfg.slv_cfg.max_r_latency = 10;                 // 첫 R beat 지연 최대 10사이클
    cfg.slv_cfg.max_b_latency = 10;                 // B 응답 지연 최대 10사이클
  endfunction                                       // configure 끝

  function void build_phase(uvm_phase phase);       // build 단계
    super.build_phase(phase);                       // env 생성 (부모)
    axil_fifo = new("axil_fifo", this);             // 버스 관찰 FIFO 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계 (env의 connect_phase 뒤)
    super.connect_phase(phase);                     // 부모 connect_phase 호출
    env.axil_agt.ap.connect(axil_fifo.analysis_export);  // axil_monitor가 본 접근 -> 이 테스트
  endfunction                                       // connect_phase 끝

  virtual task run_jobs();                          // 조합을 섞어 job 실행
    int unsigned order[];                           // job별 조합 번호
    bit          ok = 1;                            // 지금까지 JOB_TIMEOUT 없음
    alloc(n_jobs + 1);                              // job별 배열 (번호 1부터)
    order = new[n_jobs];                            // 조합 순서
    foreach (order[i]) order[i] = i % 4;            // 조합마다 같은 수
    for (int i = n_jobs - 1; i > 0; i--) begin      // 섞기 (Fisher-Yates, 절차적으로)
      int unsigned r = $urandom_range(i, 0);        // 바꿀 자리
      int unsigned t = order[i];                    // 임시
      order[i] = order[r]; order[r] = t;            // 바꿈
    end                                             // for 끝
    fork                                            // 버스 관찰 시작 (테스트 끝까지)
      watch_axil();                                 // AXI-Lite 접근
      watch_irq();                                  // interrupt 핀
      watch_w();                                    // m00 W handshake
    join_none                                       // 기다리지 않음
    for (int unsigned k = 1; k <= n_jobs && ok; k++)  // job마다 (JOB_TIMEOUT이면 멈춤: DUT가 아직 돌고 있을 수 있음)
      run_irq_job(k, order[k - 1], ok);             // 실행과 도달 확인
    for (int c = 0; c < 4; c++)                     // 조합마다
      if (combo_hits[c] == 0)                       // 노린 상태에 간 job이 없으면
        `uvm_error("SCENARIO_MISS", $sformatf("IER=%b GIE=%0d: no job reached the target state (%0d job(s) run)",  // 미도달
                                              combo_ier(c), combo_gie(c), combo_jobs[c]))  // 조합, job 수
    `uvm_info("IRQ_READY", $sformatf("summary: reached/run IER=10 GIE=0 %0d/%0d, IER=11 GIE=0 %0d/%0d, IER=10 GIE=1 %0d/%0d, IER=11 GIE=1 %0d/%0d | bus: ISR reads=%0d, interrupt rises=%0d",  // 요약
                                     combo_hits[0], combo_jobs[0], combo_hits[1], combo_jobs[1],  // GIE=0 조합
                                     combo_hits[2], combo_jobs[2], combo_hits[3], combo_jobs[3],  // GIE=1 조합
                                     n_isr_reads, n_rises), UVM_LOW)  // 버스 수
  endtask                                           // run_jobs 끝

  // job k를 조합 c로 실행하고 노린 상태에 갔는지 확인. ok = JOB_TIMEOUT 없음
  task run_irq_job(int unsigned k, int unsigned c, output bit ok);  // job 번호, 조합 번호, 결과
    dma_job      j   = make_job(k - 1);             // 위치, 크기, 값은 기본 방식 (1MB 창 k-1)
    bit          gie = combo_gie(c);                // GIE
    bit [1:0]    ier = combo_ier(c);                // IER
    dma_job_vseq s;                                 // 단계별 vseq
    j.mode = (gie && ier[ISR_AP_DONE]) ? DONE_IRQ : DONE_POLL;  // dma_predictor가 정하는 mode와 같게 (로그용)
    want_gie[k] = gie; want_ier[k] = ier; job_beats[k] = j.beats();  // 노린 값
    combo_jobs[c]++;                                // 조합별 job 수
    drain = 0;                                      // 완료 대기 단계
    cur   = k;                                      // 버스 관찰이 이 job으로 셈
    `uvm_info("IRQ_READY", $sformatf("job%0d: IER=%b GIE=%0d, %0d beats", k, ier, gie, j.beats()), UVM_LOW)  // 시작 로그
    // 1. 메모리, 레지스터, start, 완료 대기
    s = make_vseq(j, gie, ier);                     // 조합의 GIE/IER
    if (gie && ier[ISR_AP_DONE]) begin              // IER=11 GIE=1
      s.done_wait = dma_job_vseq::ISR_LOOP;         // 인터럽트 두 번 (ready, done)
      s.n_irq     = 2;                              // (위)
    end else if (gie) begin                         // IER=10 GIE=1
      s.done_wait       = dma_job_vseq::IRQ;        // ready 인터럽트 한 번 (done 인터럽트 없음)
      s.wait_idle_after = 0;                        // 완료는 아래 2에서 기다림
    end else begin                                  // GIE=0
      s.done_wait = dma_job_vseq::POLL_DONE;        // done polling (첫 읽기들에서 ready)
    end                                             // if 끝
    s.start(env.vsqr);                              // 실행
    ok = !s.timed_out;                              // JOB_TIMEOUT 없음
    // 2. IER=10 GIE=1: 같은 job의 done polling (시간 한도 있음)
    if (ok && gie && !ier[ISR_AP_DONE]) begin       // ready 인터럽트만 받은 job
      s = make_vseq(j, gie, ier);                   // 같은 job
      s.do_prep = 0; s.do_program = 0; s.do_start = 0;  // 완료 대기만
      s.done_wait = dma_job_vseq::POLL_DONE;        // done polling, 그다음 idle
      s.start(env.vsqr);                            // 실행
      ok = !s.timed_out;                            // JOB_TIMEOUT 없음
    end                                             // if 끝
    // 3. GIE=0: GIE=1로 레지스터를 다시 써서 남은 ISR이 올린 interrupt로 ISR 읽기 (start 없음)
    if (ok && !gie) begin                           // GIE=0 job
      drain = 1;                                    // 남은 ISR 읽기 단계
      s = make_vseq(j, 1'b1, ier);                  // 같은 레지스터 값, GIE만 1
      s.do_prep = 0; s.do_start = 0;                // 레지스터 쓰기와 대기만
      s.done_wait = dma_job_vseq::IRQ;              // interrupt -> ISR 읽기 -> AP_CTRL 읽기
      s.wait_idle_after = 0;                        // 이미 idle
      s.start(env.vsqr);                            // 실행
      ok = !s.timed_out;                            // JOB_TIMEOUT 없음
    end                                             // if 끝
    env.clocks(2);                                  // monitor가 낸 마지막 접근이 watch_axil에 도착하도록
    if (ok) check_job(k, c);                        // 도달 확인 (JOB_TIMEOUT이면 그 오류로 충분)
  endtask                                           // run_irq_job 끝

  // job j를 gie/ier 노브로 실행하는 dma_job_vseq (나머지 노브는 기본값)
  function dma_job_vseq make_vseq(dma_job j, bit gie, bit [1:0] ier);  // job, GIE, IER
    dma_job_vseq s = dma_job_vseq::type_id::create("job_vseq");  // 작업 virtual sequence 생성
    s.job = j;                                      // 같은 job (번호는 처음 vseq가 한 번만 붙임)
    s.gie = gie;                                    // GIE에 쓸 값
    s.ier = ier;                                    // IER에 쓸 값
    return s;                                       // vseq
  endfunction                                       // make_vseq 끝

  // job k가 노린 상태에 갔는지 (버스 관찰). 못 갔으면 SCENARIO_MISS, 갔으면 조합 c의 도달 수 증가
  function void check_job(int unsigned k, int unsigned c);  // job 번호, 조합 번호
    string miss;                                    // 못 간 항목
    if (n_start[k] != 1)                            // start 쓰기가 한 번이 아니면
      miss = {miss, $sformatf(" %0d start write(s), expected 1;", n_start[k])};  // 항목
    else if (start_ier[k] != want_ier[k] || start_gie[k] != want_gie[k])  // start 때 조합이 다르면
      miss = {miss, $sformatf(" IER=%b GIE=%0d on the bus at start;", start_ier[k], start_gie[k])};  // 항목
    if (n_ready[k] == 0)     miss = {miss, " no AP_CTRL read with ready=1;"};  // AP_CTRL.ready
    if (n_isr_ready[k] == 0) miss = {miss, " no ISR read with ISR[1]=1;"};  // ISR[1]
    if (want_ier[k][ISR_AP_DONE] && n_isr_done[k] == 0)  // IER=11인데 ISR[0]을 못 읽음
      miss = {miss, " no ISR read with ISR[0]=1;"}; // 항목
    if (want_gie[k] && n_rise_early[k] == 0)        // GIE=1인데 job 도중 interrupt가 안 올라감
      miss = {miss, " no interrupt rise before the last W beat (ready interrupt);"};  // 항목
    if (want_gie[k] && want_ier[k][ISR_AP_DONE] && n_rise_wait[k] < 2)  // IER=11 GIE=1인데 상승이 모자람
      miss = {miss, $sformatf(" %0d interrupt rise(s) while waiting, expected 2 (ready, done);", n_rise_wait[k])};  // 항목
    `uvm_info("IRQ_READY", $sformatf("job%0d: IER=%b GIE=%0d | start writes=%0d (bus IER=%b GIE=%0d) | ISR reads:%s | AP_CTRL ready=1 reads=%0d | interrupt rises: waiting=%0d (before last W=%0d) drain=%0d | W beats=%0d/%0d",  // job 요약
                                     k, want_ier[k], want_gie[k], n_start[k], start_ier[k], start_gie[k], isr_values[k],  // 조합, start, ISR
                                     n_ready[k], n_rise_wait[k], n_rise_early[k], n_rise_drain[k], n_w[k], job_beats[k]), UVM_LOW)  // ready, interrupt, W
    if (miss != "")                                 // 못 간 항목이 있으면
      `uvm_error("SCENARIO_MISS", $sformatf("job%0d IER=%b GIE=%0d:%s", k, want_ier[k], want_gie[k], miss))  // 미도달
    else                                            // 모두 갔으면
      combo_hits[c]++;                              // 조합 도달 수
  endfunction                                       // check_job 끝

  // AXI-Lite 접근 (axil_monitor): 쓴 GIE/IER, start 쓰기, ISR과 AP_CTRL 읽기값을 지금 job으로 셈
  task watch_axil();                                // 버스 관찰
    axil_pkg::axil_item t;                          // 접근 하나
    forever begin                                   // 계속 반복
      axil_fifo.get(t);                             // 다음 접근
      if (t.write) begin                            // 쓰기
        if (t.addr == ADDR_GIE) bus_gie = t.data[0];      // GIE
        if (t.addr == ADDR_IER) bus_ier = t.data[1:0];    // IER
        if (t.addr == ADDR_AP_CTRL && t.data[AP_START] && cur != 0) begin  // start 쓰기
          n_start[cur]++;                           // 수
          start_gie[cur] = bus_gie;                 // 그때 GIE
          start_ier[cur] = bus_ier;                 // 그때 IER
        end                                         // if 끝
      end else if (cur != 0) begin                  // job 중 읽기
        if (t.addr == ADDR_ISR) begin               // ISR
          n_isr_reads++;                            // 전체 수
          isr_values[cur] = {isr_values[cur], $sformatf(" 0x%0h", t.data)};  // 값 기록
          if (t.data[ISR_AP_READY]) n_isr_ready[cur]++;  // ISR[1]
          if (t.data[ISR_AP_DONE])  n_isr_done[cur]++;   // ISR[0]
        end                                         // if 끝
        if (t.addr == ADDR_AP_CTRL && t.data[AP_READY]) n_ready[cur]++;  // AP_CTRL.ready
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // watch_axil 끝

  // interrupt 핀 (에지 직전 값): 상승을 지금 job과 단계로 셈. 완료 대기 중이면 마지막 W beat 전인지도
  task watch_irq();                                 // 버스 관찰
    axil_pkg::axil_vif v = env.ctl_vif;             // 제어 interface
    bit                prev;                        // 지난 에지의 핀
    forever begin                                   // 계속 반복
      @(v.moncb);                                   // 매 클럭 에지
      if (v.moncb.interrupt === 1'b1 && !prev && cur != 0) begin  // 상승
        n_rises++;                                  // 전체 수
        if (drain) n_rise_drain[cur]++;             // 남은 ISR 읽기 단계
        else begin                                  // 완료 대기 단계
          n_rise_wait[cur]++;                       // 수
          if (n_w[cur] < job_beats[cur]) n_rise_early[cur]++;  // 마지막 W beat 전 (= done 전)
        end                                         // if 끝
      end                                           // if 끝
      prev = (v.moncb.interrupt === 1'b1);          // 다음 에지용
    end                                             // forever 끝
  endtask                                           // watch_irq 끝

  // m00 W handshake를 지금 job으로 셈
  task watch_w();                                   // 버스 관찰
    axi4_vif v = env.mem_agt.vif;                   // m00 interface
    forever begin                                   // 계속 반복
      @(v.moncb);                                   // 매 클럭 에지
      if (cur != 0 && v.moncb.wvalid === 1'b1 && v.moncb.wready === 1'b1) n_w[cur]++;  // W handshake
    end                                             // forever 끝
  endtask                                           // watch_w 끝

  // job별 배열 할당 (n = job 수 + 1)
  function void alloc(int unsigned n);              // 크기
    want_gie = new[n];  want_ier = new[n];  job_beats = new[n];  // 노린 값
    n_start = new[n];  start_gie = new[n];  start_ier = new[n];  // start
    n_isr_ready = new[n];  n_isr_done = new[n];  n_ready = new[n];  isr_values = new[n];  // 읽기
    n_w = new[n];  n_rise_wait = new[n];  n_rise_early = new[n];  n_rise_drain = new[n];  // W, interrupt
  endfunction                                       // alloc 끝

  function bit       combo_gie(int unsigned c); return c[1]; endfunction  // 조합 c의 GIE
  function bit [1:0] combo_ier(int unsigned c); return c[0] ? 2'b11 : 2'b10; endfunction  // 조합 c의 IER (ready만 / 둘 다)
endclass                                            // 클래스 끝
