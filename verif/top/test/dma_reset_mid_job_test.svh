// dma_reset_mid_job_test : H4 가설 확인용 directed test (사양 검사 -> 가설이 맞으면 FAIL)
//   H4: adder(axis_adder.v:99, 114, 123)에는 리셋이 없어(s_axis_areset 포트를 쓰지 않음, dma_ip_top.v:301 연결은 됨)
//       작업 도중 리셋하면 adder에 남은 beat가 리셋 뒤 FIFO 입력 skid로 들어가(첫 beat는 BUG-001로 두 번, skid_buffer.v:67-70)
//       start 없이 AW 없는 W로 나감 (WVALID = FIFO 출력 valid, wdma.v:497)
//   사양: 리셋 뒤 DMA는 다음 start 전까지 m00에서 조용해야 함 -> 기존 검사 SB_NO_JOB_BUS(실행 중인 job 없이 온 W)가 판정.
//         slave는 AW보다 먼저 온 W도 받으므로 그 뒤 job B, C의 W가 밀려 AXI_WLAST, SB_DATA, AXI_PENDING도 날 수 있음. 검사를 바꾸지 않음
//   자극 (테스트 중간 리셋 1번, job은 모두 polling):
//     a. job A 256 beat를 시작만 함 (완료를 기다리지 않음). W handshake W_STOP개 뒤 w_ready_pct=0 -> FIFO(64)와 skid, adder가 참
//        -> RREADY=0이 STALL_EDGES 에지 이어지면 dma_reset_vseq로 RESET_CYCLES 사이클 리셋 (A는 dma_predictor가 중단).
//        리셋이 걸려 있는 동안 w_ready_pct=100으로 되돌림 (slave driver는 리셋이 풀린 첫 에지부터 이 값을 씀)
//     b. 리셋 해제 뒤 OBSERVE_CYCLES 사이클 동안 start 없이 관찰
//     c. job B 32 beat, job C 32 beat (B가 JOB_TIMEOUT이면 C는 건너뜀: idle이 오지 않아 시작할 수 없음)
//   노린 상태 (버스 관찰, 못 가면 SCENARIO_MISS): 리셋이 걸리기 직전 adder d2_tvalid=1.
//     RREADY = adder s_axis_tready = ~d2_tvalid | FIFO 입력 skid s_ready_reg (axis_adder.v:96, rdma.v:467)라
//     RREADY=0이면 d2_tvalid=1. stall을 본 뒤 TB가 본 첫 리셋 에지(그 표본은 DUT가 아직 리셋 전인 값)까지 RREADY가 계속 0이고,
//     리셋 때 R handshake 수 - W handshake 수(DUT 안에 남은 beat)가 MIN_INFLIGHT(FIFO 깊이) 이상이어야 함.
//     그 뒤 리셋 에지들의 RREADY는 [H4] 증거 줄에 세기만 함 (가설이 맞으면 d2_tvalid가 남아 계속 0, adder를 리셋하도록
//     고친 RTL이면 1이 될 수 있음. 판정 조건에 넣으면 고친 RTL에서도 SCENARIO_MISS가 나서 PASS(XPASS)가 나올 수 없음)
//   버스 관찰 (bus_watch): 리셋 때 R/W 수, 해제 에지부터 첫 WVALID 표본까지 에지 수, job B 전 W beat(데이터가 A의 몇 번째 beat
//     + value와 같은지)와 AW/AR 수를 [H4] 줄로 남김. TB는 해제 에지를 이미 1로 읽음 (dma_reset_if 주석)
class dma_reset_mid_job_test extends dma_base_test;  // 기본 테스트 상속
  `uvm_component_utils(dma_reset_mid_job_test)      // factory 등록
  localparam int unsigned A_BEATS        = 256;     // job A 크기 (beat)
  localparam int unsigned BC_BEATS       = 32;      // job B, C 크기 (beat)
  localparam int unsigned W_STOP         = 32;      // WREADY를 막기 전 W handshake 수
  localparam int unsigned STALL_EDGES    = 20;      // RREADY=0이 이만큼 이어지면 리셋
  localparam int unsigned RESET_CYCLES   = 16;      // 리셋 사이클 (dma_reset_vseq n_cycles)
  localparam int unsigned OBSERVE_CYCLES = 100;     // 리셋 뒤 start 없이 관찰하는 사이클
  localparam int unsigned MIN_INFLIGHT   = 64;      // 리셋 때 DUT 안에 남은 beat 하한 (FIFO 깊이, dma_ip_top.v u_sync_fifo)
  localparam int unsigned MAX_WAIT       = 5000;    // 단계마다 기다리는 최대 사이클 (넘으면 SCENARIO_MISS)
  localparam int unsigned MATCH_BACK     = 4;       // stale beat를 맞춰 볼 A의 마지막 R beat 수
  localparam int unsigned MAX_STALE_LOG  = 8;       // 데이터를 로그로 남길 stale W beat 수

  dma_job      ja;                                  // job A (stale beat 데이터를 A의 beat와 맞춰 봄)
  // bus_watch가 채움
  int unsigned n_r, n_w;                            // R, W handshake 수 (리셋 에지 제외, monitor와 같음)
  bit          armed;                               // W를 막은 뒤 stall 감시 중
  bit          stalled;                             // RREADY=0이 STALL_EDGES 에지 이어짐
  int unsigned low_run;                             // RREADY=0 연속 에지 수
  bit          hold;                                // stall 뒤 TB가 본 첫 리셋 에지까지 (RREADY가 계속 0이어야 하는 구간)
  bit          rready_hi;                           // hold 구간에서 RREADY=1을 봄 (d2_tvalid=0이 됐을 수 있음 -> 노린 상태 아님)
  int unsigned hold_edges;                          // hold 구간 에지 수 (stall 다음 에지 ~ 첫 리셋 에지)
  int unsigned n_rst_edges;                         // TB가 본 리셋 에지 수
  int unsigned n_rst_rready_low;                    // 첫 리셋 에지 뒤 리셋 에지 중 RREADY=0인 수 (증거만, 판정에 쓰지 않음)
  int unsigned r_at_rst, w_at_rst;                  // TB가 본 첫 리셋 에지 전까지 R, W handshake 수
  time         t_rst, t_rel;                        // TB가 본 첫 리셋 에지, 해제 에지
  bit          after_rel;                           // 해제 뒤 job B 시작 전 (stale 관찰 창)
  int unsigned rel_edges;                           // 해제 에지 뒤 에지 수
  int          first_wvalid = -1;                   // 해제 에지부터 첫 WVALID=1 표본까지 에지 수 (-1: 없음)
  time         t_first_wvalid;                      // 그 에지 시각
  int unsigned n_stale_aw, n_stale_ar;              // 관찰 창의 AW, AR handshake 수
  bit [63:0]   stale_d[$];                          // 관찰 창 W handshake 데이터
  bit          stale_last[$];                       // 그 WLAST
  time         stale_t[$];                          // 그 시각

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 3;                                     // job A, B, C (크기는 run_jobs가 정함)
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // a -> b -> c
    dma_job_vseq   a_seq;                           // job A (시작만)
    dma_reset_vseq rs;                              // 테스트 중간 리셋
    dma_job        jb, jc;                          // job B, C
    int unsigned   waited;                          // 기다린 사이클
    bit            ok;                              // job B가 끝났는지
    fork bus_watch(); join_none                     // 버스 관찰 시작
    // a. job A: 메모리, 레지스터, start만
    ja = make_job(0);                               // 값과 위치는 기본 방식 (polling)
    ja.bytes = A_BEATS * BEAT;                      // 256 beat
    a_seq = dma_job_vseq::type_id::create("a_vseq");  // 작업 virtual sequence
    a_seq.job     = ja;                             // job A
    a_seq.do_wait = 0;                              // 완료를 기다리지 않음 (리셋으로 중단할 job)
    a_seq.start(env.vsqr);                          // start 쓰기까지
    while (n_w < W_STOP && waited < MAX_WAIT) begin env.clocks(1); waited++; end  // W handshake W_STOP개까지
    if (n_w < W_STOP)                               // 못 감
      `uvm_error("SCENARIO_MISS", $sformatf("job A: only %0d W handshakes in %0d cycles (expected %0d before stopping WREADY)", n_w, waited, W_STOP))  // 판정 불가
    cfg.slv_cfg.w_ready_pct = 0;                    // WREADY 막음 (driver가 다음 사이클부터 읽음)
    armed = 1;                                      // stall 감시 시작
    `uvm_info("H4", $sformatf("job A: %0d W / %0d R handshakes, w_ready_pct -> 0", n_w, n_r), UVM_LOW)  // 진행 로그
    waited = 0;                                     // 다시 셈
    while (!stalled && waited < MAX_WAIT) begin env.clocks(1); waited++; end  // RREADY=0이 STALL_EDGES 에지 이어질 때까지
    if (!stalled)                                   // 못 감 (그래도 리셋해서 테스트를 끝냄)
      `uvm_error("SCENARIO_MISS", $sformatf("RREADY never stayed low for %0d edges within %0d cycles (R=%0d W=%0d)", STALL_EDGES, waited, n_r, n_w))  // 판정 불가
    // 리셋: 걸려 있는 동안 WREADY를 되돌림 (리셋 전에 되돌리면 FIFO가 빠져 adder가 비워짐)
    rs = dma_reset_vseq::type_id::create("rs");     // 리셋 sequence
    rs.n_cycles = RESET_CYCLES;                     // 16 사이클
    fork                                            // 리셋과 WREADY 되돌리기
      rs.start(env.vsqr);                           // lock, AXI-Lite 빈 것 확인, 리셋, 해제 뒤 5 에지, unlock
      begin                                         // 리셋이 걸린 뒤
        wait (env.vsqr.rst_vif.rst_n === 1'b0);     // rst_n = 0
        cfg.slv_cfg.w_ready_pct = 100;              // slave는 리셋이 풀린 첫 에지부터 WREADY=1
      end                                           // 끝
    join                                            // 둘 다 끝날 때까지
    `uvm_info("H4", $sformatf("reset @%0t (released @%0t): R=%0d W=%0d handshakes before reset, %0d beats left in the DUT (min %0d) | RREADY low for %0d edges, then %0d edges up to the first reset edge, RREADY high in that span=%0d",  // 리셋 요약
                              t_rst, t_rel, r_at_rst, w_at_rst, int'(r_at_rst) - int'(w_at_rst), MIN_INFLIGHT,  // 수
                              STALL_EDGES, hold_edges, rready_hi), UVM_LOW)  // RREADY (노린 상태)
    `uvm_info("H4", $sformatf("during reset (evidence only): RREADY low on %0d of %0d later reset edges (adder d2_tvalid kept through the reset if all)",  // 리셋 중 RREADY
                              n_rst_rready_low, (n_rst_edges > 0) ? n_rst_edges - 1 : 0), UVM_LOW)  // 수
    if (int'(r_at_rst) - int'(w_at_rst) < int'(MIN_INFLIGHT))  // FIFO가 차지 않았음
      `uvm_error("SCENARIO_MISS", $sformatf("only %0d beats in the DUT at reset (R=%0d W=%0d), expected >= %0d: FIFO and adder not filled", int'(r_at_rst) - int'(w_at_rst), r_at_rst, w_at_rst, MIN_INFLIGHT))  // 판정 불가
    if (!stalled || rready_hi)                      // 리셋 직전 d2_tvalid=1을 보이지 못함
      `uvm_error("SCENARIO_MISS", $sformatf("RREADY not held low from the stall to the first reset edge (stalled=%0d, RREADY high seen=%0d): adder d2_tvalid=1 before reset not shown", stalled, rready_hi))  // 판정 불가
    // b. start 없이 관찰
    env.clocks(OBSERVE_CYCLES);                     // 관찰 (dma_reset_vseq가 해제 뒤 5 에지를 이미 기다림)
    after_rel = 0;                                  // 관찰 창 끝
    report_stale();                                 // [H4] 줄
    // c. job B, C
    jb = make_job(1);                               // 창 1
    jb.bytes = BC_BEATS * BEAT;                     // 32 beat
    run_bc("B", jb, ok);                            // 실행
    if (!ok) return;                                // 끝나지 않으면 C를 시작할 수 없음 (idle 대기에 시간 한도가 없음)
    jc = make_job(2);                               // 창 2
    jc.bytes = BC_BEATS * BEAT;                     // 32 beat
    run_bc("C", jc, ok);                            // 실행
  endtask                                           // run_jobs 끝

  // job B/C 하나를 끝까지 (dma_base_test::run_job과 같고 JOB_TIMEOUT 여부를 돌려줌)
  task run_bc(string name, dma_job j, output bit ok);  // 이름, job, 끝났는지
    dma_job_vseq seq = dma_job_vseq::type_id::create("job_vseq");  // 작업 virtual sequence
    seq.job = j;                                    // job
    seq.start(env.vsqr);                            // 실행 (끝나거나 JOB_TIMEOUT까지)
    ok = !seq.timed_out;                            // 결과
    if (!ok) `uvm_info("H4", $sformatf("job %s did not finish (JOB_TIMEOUT): later jobs skipped", name), UVM_LOW)  // 다음 job 건너뜀
  endtask                                           // run_bc 끝

  // job A beat k의 기대 W 데이터 (src는 A 동안 바뀌지 않음: dst는 같은 창의 512KB 지점)
  function bit [63:0] a_beat(int unsigned k);       // beat 번호
    bit [63:0] d;                                   // 기대 beat
    for (int unsigned i = 0; i < BEAT; i++)         // 바이트마다
      d[i*8 +: 8] = dma_ref_model::model_byte(env.mem_agt.mem.rd8(ja.src + k * BEAT + i), ja.value);  // 원본 + value[7:0]
    return d;                                       // 돌려줌
  endfunction                                       // a_beat 끝

  // 관찰 창의 W beat와 A의 마지막 R beat들을 맞춰 [H4] 줄로 남김
  function void report_stale();                     // 관찰 결과
    int    lo, hi, k;                               // 맞춰 볼 A beat 범위, 찾은 beat
    string what;                                    // 맞춘 결과
    hi = int'(r_at_rst) - 1;                        // A의 마지막 R beat (리셋 전 d1)
    lo = hi - int'(MATCH_BACK) + 1;                 // 범위 시작
    if (lo < 0) lo = 0;                             // 음수 방지
    `uvm_info("H4", $sformatf("after release @%0t, no start for %0d cycles: first WVALID sample %0d edges after release (@%0t) | W beats=%0d AW=%0d AR=%0d",  // 관찰 요약
                              t_rel, OBSERVE_CYCLES, first_wvalid, t_first_wvalid, stale_d.size(), n_stale_aw, n_stale_ar), UVM_LOW)  // 값들
    foreach (stale_d[i]) begin                      // W beat마다
      if (i >= MAX_STALE_LOG) break;                // 앞 몇 개만
      k = -1;                                       // 못 찾음
      for (int b = hi; b >= lo; b--)                // 뒤 beat부터
        if (a_beat(b) == stale_d[i]) begin k = b; break; end  // 같은 beat
      if (k >= 0) what = $sformatf("= job A beat %0d + value (A R beats 0..%0d before reset)", k, hi);  // 찾음
      else        what = $sformatf("matches no job A beat in [%0d,%0d]", lo, hi);  // 못 찾음 (?:의 문자열은 폭이 채워지므로 if)
      `uvm_info("H4", $sformatf("W beat %0d without job @%0t: data=0x%016h WLAST=%0d %s", i, stale_t[i], stale_d[i], stale_last[i], what), UVM_LOW)  // beat 로그
    end                                             // foreach 끝
  endfunction                                       // report_stale 끝

  // m00 버스를 매 클럭 봄. TB가 본 리셋 에지의 handshake는 세지 않음 (axi4_slave_monitor와 같음)
  task bus_watch();                                 // 버스 관찰
    axi4_vif vif = env.mem_agt.vif;                 // m00 interface
    bit      was_rst;                               // 지난 에지가 리셋 에지
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지 (값은 에지 직전 표본)
      if (vif.rst_n !== 1'b1) begin                 // TB가 본 리셋 에지
        if (n_rst_edges == 0) begin                 // 첫 리셋 에지 (표본은 DUT가 아직 리셋 전인 값)
          r_at_rst = n_r;  w_at_rst = n_w;          // 리셋 전 수
          t_rst    = $time;                         // 시각
          if (hold) begin                           // stall 뒤
            hold_edges++;                           // 수 증가
            if (vif.moncb.rready !== 1'b0) rready_hi = 1;  // 리셋 직전 RREADY=1이면 d2_tvalid=0일 수 있음
          end                                       // if 끝
          hold = 0;                                 // 노린 상태 확인 구간 끝
        end else if (vif.moncb.rready === 1'b0) n_rst_rready_low++;  // 그 뒤 리셋 에지: RREADY=0 수 (증거만)
        n_rst_edges++;                              // 수 증가
        was_rst = 1;                                // 다음 에지가 해제 에지일 수 있음
        continue;                                   // handshake로 보지 않음
      end                                           // if 끝
      if (was_rst) begin                            // 해제 에지 (TB는 이미 1로 읽음)
        was_rst   = 0;                              // 한 번만
        t_rel     = $time;                          // 시각
        after_rel = 1;                              // 관찰 창 시작
        rel_edges = 0;                              // 해제 에지 = 0
      end else if (after_rel) rel_edges++;          // 해제 뒤 에지 수
      if (hold) begin                               // stall 뒤 리셋 전
        hold_edges++;                               // 수 증가
        if (vif.moncb.rready !== 1'b0) rready_hi = 1;  // RREADY가 다시 1 (WREADY=0이면 일어나면 안 됨)
      end else if (armed && !stalled) begin         // stall 감시
        if (vif.moncb.rready === 1'b0) low_run++; else low_run = 0;  // RREADY=0 연속 수
        if (low_run >= STALL_EDGES) begin stalled = 1; hold = 1; end  // 노린 stall
      end                                           // if 끝
      if (vif.moncb.rvalid === 1'b1 && vif.moncb.rready === 1'b1) n_r++;  // R handshake
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) n_w++;  // W handshake
      if (!after_rel) continue;                     // 관찰 창 밖
      if (first_wvalid < 0 && vif.moncb.wvalid === 1'b1) begin  // 해제 뒤 첫 WVALID
        first_wvalid   = rel_edges;                 // 에지 수
        t_first_wvalid = $time;                     // 시각
      end                                           // if 끝
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) n_stale_aw++;  // AW handshake
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) n_stale_ar++;  // AR handshake
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) begin  // W handshake
        stale_d.push_back(vif.moncb.wdata);         // 데이터
        stale_last.push_back(vif.moncb.wlast);      // WLAST
        stale_t.push_back($time);                   // 시각
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // bus_watch 끝
endclass                                            // 클래스 끝
