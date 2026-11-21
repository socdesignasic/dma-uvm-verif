// dma_size_128mib_test : H5 가설 확인용 directed test (사양 검사 -> 가설이 맞으면 FAIL)
//   H5: beat 카운터가 24비트([31-NUM_SAMPLE_IN_AXI_DATA:0])라 transfer_byte >= 2^27(128MiB)이면 beat 수가
//       (bytes >> 3) mod 2^24로 잘림. 나머지가 0이면 AR/AW 없이 멈춤 (rdma.v:206,332,401 / wdma.v:213,350,420)
//   사양: TRANSFER_BYTE는 32비트 RW 레지스터(control_s_axi.v:78-79)이고 상한이 문서에 없음 -> 쓴 32비트 값 그대로 전송해야 함.
//         기대값은 dma_predictor/dma_scoreboard가 레지스터 값으로 만듦 (1MiB 넘는 job은 lazy 모델). 검사를 바꾸지 않음
//   단계 (a, b 뒤에 테스트 중간 리셋 dma_reset_vseq. 창 뒤 idle을 기다리지 않음: 끝나지 않는 DUT를 한도 없이 polling하지 않도록)
//     a: bytes=0x0800_0040, src=0x1000_0000 (앞 64KB만 초기화), dst=0x3000_0000. WINDOW 3000사이클, 100사이클마다 AP_CTRL 읽기.
//        가설: AR 1개(ARLEN=7), AW 1개, W 8 beat 뒤 done -> SB_AR_LIST, SB_AW_LIST, AP_CTRL 예측 불일치(IRQ, REG_STATUS).
//        사양대로면 16 beat AR이 계속 옴 (3000사이클에 읽을 수 있는 양 < 64KB라 초기화 안 된 메모리는 읽지 않음)
//     b: bytes=0x0800_0000 (2^24 beat -> 잘리면 0). WINDOW 2000사이클, 100사이클마다 AP_CTRL 읽기, AR이 하나도 없으면 JOB_TIMEOUT.
//        가설: AR/AW 없이 idle=0으로 멈춤 -> JOB_TIMEOUT
//     c: 64 beat 보통 job (대조, PASS해야 함)
//   리셋 전에는 AR을 막고(ar_ready_pct=0) m00 R/W가 QUIET 사이클 조용할 때까지 기다림 (상한 MAX_DRAIN): 사양대로 계속 읽는
//   DUT에서도 adder/FIFO에 남은 beat 없이 리셋하려고 (작업 도중 리셋의 남은 beat는 H4가 따로 다룸). 가설대로면 이미 조용함
//   메모리: 128MiB를 만들지 않음 (dma_job_vseq::prep_mem은 bytes 크기 배열을 만들므로 do_prep=0, 대신 이 테스트의 prep_mem)
//   버스 관찰 (bus_watch, ctl_watch): 단계별 m00 AR/AW/W/B 수와 beat 합, 첫 ARLEN/AWLEN, AP_CTRL 읽기의 idle/done을 [H5] 줄로 남김.
//   노린 상태에 못 가면 SCENARIO_MISS: a에서 AR이 하나도 없음, b에서 idle=0인 AP_CTRL 읽기가 없음 (둘 다 start를 받지 않음)
class dma_size_128mib_test extends dma_base_test;   // 기본 테스트 상속
  `uvm_component_utils(dma_size_128mib_test)        // factory 등록
  localparam bit [31:0]   SRC       = 32'h1000_0000;  // a, b 원본 (창 0 시작)
  localparam bit [31:0]   DST       = 32'h3000_0000;  // a, b 대상
  localparam bit [31:0]   BYTES_A   = 32'h0800_0040;  // 2^27 + 64: 잘리면 8 beat
  localparam bit [31:0]   BYTES_B   = 32'h0800_0000;  // 2^27: 잘리면 0 beat
  localparam int unsigned SRC_INIT  = 32'h1_0000;   // 초기화하는 src 앞부분 (64KB)
  localparam int unsigned WIN_A     = 3000;         // a 창 (사이클)
  localparam int unsigned WIN_B     = 2000;         // b 창 (사이클)
  localparam int unsigned POLL      = 100;          // 창 안 AP_CTRL 읽기 간격 (사이클)
  localparam int unsigned QUIET     = 32;           // 리셋 전 m00 R/W가 조용해야 하는 연속 사이클
  localparam int unsigned MAX_DRAIN = 4000;         // 그 대기의 상한 (사이클)
  localparam int unsigned NS        = 4;            // 단계 칸 수 (0 = 단계 밖, 1 = a, 2 = b, 3 = c)

  int unsigned step;                                // bus_watch/ctl_watch가 세는 단계
  int unsigned n_ar[NS], ar_beats[NS];              // 단계별 AR 수, AR beat 합
  int unsigned n_aw[NS], aw_beats[NS];              // 단계별 AW 수, AW beat 합
  int unsigned n_w[NS], n_b[NS];                    // 단계별 W beat 수, B 수
  int          first_arlen[NS], first_awlen[NS];    // 단계별 첫 ARLEN, AWLEN (-1 = 없음)
  time         t_first_ar[NS], t_last_w[NS];        // 단계별 첫 AR handshake, 마지막 W beat 시각
  int unsigned n_ctrl_rd[NS], n_ctrl_busy[NS], n_ctrl_done[NS];  // 단계별 AP_CTRL 읽기 수, 그중 idle=0, done=1
  bit [11:0]   rd_addr;                             // 마지막 AXI-Lite AR 주소 (R과 짝지음, 한 번에 하나)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 3; min_beats = 64; max_beats = 64;     // a, b, c (크기는 c에만 쓰임, a와 b는 run_jobs가 정함)
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // a -> 리셋 -> b -> 리셋 -> c
    dma_job c;                                      // 대조 job
    foreach (first_arlen[s]) begin first_arlen[s] = -1; first_awlen[s] = -1; end  // 아직 없음
    fork bus_watch(); ctl_watch(); join_none        // 버스 관찰 시작 (clocking block마다 따로)
    run_window_job(1, BYTES_A, WIN_A, 0);           // a: 끝까지 기다리지 않음, AR 하한 없음 (판정은 scoreboard와 predictor)
    drain_and_reset(1);                             // AR 막고 조용해지면 리셋
    run_window_job(2, BYTES_B, WIN_B, 1);           // b: 창 안 AR이 없으면 JOB_TIMEOUT
    drain_and_reset(2);                             // AR 막고 조용해지면 리셋
    c = make_job(1);                                // c: 64 beat, 창 1 (a, b 영역과 겹치지 않음)
    step = 3;                                       // c 단계
    `uvm_info("H5", $sformatf("step c: control job, %0d bytes (job number and addresses in the JOB line)", c.bytes), UVM_LOW)  // 시작 로그
    run_job(c);                                     // 보통 job (끝나거나 JOB_TIMEOUT까지)
    report_step(3, "c", c.bytes);                   // 요약
    step = 0;                                       // 단계 밖
    // 노린 상태에 갔는지 (start를 받았는지)
    if (n_ar[1] == 0)                               // a: AR이 하나도 없음
      `uvm_error("SCENARIO_MISS", "step a: no m00 AR handshake, the 0x08000040 start was never taken")  // 판정 불가
    if (n_ctrl_busy[2] == 0)                        // b: DUT가 idle을 떠난 것을 못 봄
      `uvm_error("SCENARIO_MISS", $sformatf("step b: no AP_CTRL read with idle=0 (%0d reads), the 0x08000000 start was never taken", n_ctrl_rd[2]))  // 판정 불가
  endtask                                           // run_jobs 끝

  // 큰 job k를 WINDOW 방식으로 실행: 메모리 준비(이 테스트), 레지스터 설정, start, cycles 사이클 관찰 (min_ar 미만이면 JOB_TIMEOUT)
  task run_window_job(int unsigned k, bit [31:0] bytes, int unsigned cycles, int unsigned min_ar);  // 단계, 바이트 수, 창, AR 하한
    dma_job      j   = make_job(0);                 // 값과 완료 방식(polling)은 기본 방식
    dma_job_vseq seq = dma_job_vseq::type_id::create("job_vseq");  // 작업 virtual sequence
    bit [23:0]   trunc;                             // 가설의 beat 수 (24비트로 잘린 값)
    j.src   = SRC;                                  // 원본
    j.dst   = DST;                                  // 대상
    j.bytes = bytes;                                // 크기 (32비트 그대로)
    trunc   = bytes >> 3;                           // (bytes >> 3) mod 2^24
    prep_mem(j);                                    // src 앞 64KB, dst 앞뒤 guard
    seq.job             = j;                        // job
    seq.do_prep         = 0;                        // 메모리는 위에서 (bytes 크기 배열을 만들지 않음)
    seq.done_wait       = dma_job_vseq::WINDOW;     // 정해진 창만 관찰
    seq.window_cycles   = cycles;                   // 창 길이
    seq.window_poll     = POLL;                     // AP_CTRL 읽기 간격
    seq.window_min_ar   = min_ar;                   // 창 안 AR 하한
    seq.wait_idle_after = 0;                        // 창 뒤 idle을 기다리지 않음 (다음은 리셋)
    step = k;                                       // 이 단계로 셈
    `uvm_info("H5", $sformatf("step %s: bytes=0x%08h (spec %0d beats, 24-bit truncated %0d beats), %0d-cycle window, AP_CTRL read every %0d, min AR=%0d",  // 시작 로그
                              (k == 1) ? "a" : "b", bytes, j.beats(), trunc, cycles, POLL, min_ar), UVM_LOW)  // 값들
    seq.start(env.vsqr);                            // 실행 (창이 끝나면 돌아옴)
    report_step(k, (k == 1) ? "a" : "b", bytes);    // 요약
  endtask                                           // run_window_job 끝

  // 메모리 (백도어): src 앞 SRC_INIT 바이트만 랜덤, dst 앞뒤 GUARD 바이트에 A5 (희소 메모리라 쓴 바이트만 생김)
  function void prep_mem(dma_job j);                // job
    axi4_mem mem = env.mem_agt.mem;                 // 메모리 모델
    for (int unsigned i = 0; i < SRC_INIT; i++) mem.wr8(j.src + i, $urandom);  // src 앞부분
    for (int unsigned g = 1; g <= GUARD; g++) begin // guard 바이트마다
      mem.wr8(j.dst - g, 8'hA5);                    // dst 앞
      mem.wr8(j.dst + j.bytes - 1 + g, 8'hA5);      // dst 뒤
    end                                             // for 끝
  endfunction                                       // prep_mem 끝

  // 단계 k 뒤: AR을 막고 m00 R/W가 QUIET 사이클 조용해지면(상한 MAX_DRAIN) 리셋, 그다음 AR ready를 되돌림
  task drain_and_reset(int unsigned k);             // 단계
    virtual axi4_if vif   = env.mem_agt.vif;        // m00 interface
    int unsigned    saved = cfg.slv_cfg.ar_ready_pct;  // 되돌릴 값
    int unsigned    quiet, waited;                  // 연속 조용한 사이클, 기다린 사이클
    dma_reset_vseq  rs    = dma_reset_vseq::type_id::create("reset_vseq");  // 리셋 sequence
    string          how   = "quiet";                // 로그 (?:의 문자열 상수는 폭이 채워지므로 if로 바꿈)
    cfg.slv_cfg.ar_ready_pct = 0;                   // 새 AR을 받지 않음
    while (quiet < QUIET && waited < MAX_DRAIN) begin  // 조용해질 때까지
      @(vif.moncb);                                 // 다음 에지 (값은 에지 직전 표본)
      waited++;                                     // 기다린 사이클
      if ((vif.moncb.rvalid === 1'b1 && vif.moncb.rready === 1'b1) ||  // R handshake나
          (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1)) quiet = 0;  // W handshake가 있으면 처음부터
      else quiet++;                                 // 조용한 사이클
    end                                             // while 끝
    if (quiet < QUIET) how = "NOT quiet";           // 상한에 걸림 (그래도 리셋)
    `uvm_info("H5", $sformatf("step %s: AR blocked, m00 R/W %s after %0d cycles -> reset",  // 진행 로그
                              (k == 1) ? "a" : "b", how, waited), UVM_LOW)  // 값들
    rs.start(env.vsqr);                             // 테스트 중간 리셋 (AXI-Lite가 끝난 뒤)
    cfg.slv_cfg.ar_ready_pct = saved;               // AR ready 되돌림
    step = 0;                                       // 단계 밖
  endtask                                           // drain_and_reset 끝

  // 단계 k의 버스 요약 한 줄
  function void report_step(int unsigned k, string name, bit [31:0] bytes);  // 단계, 이름, 바이트 수
    bit [23:0] trunc = bytes >> 3;                  // 가설의 beat 수
    `uvm_info("H5", $sformatf("step %s summary: AR=%0d (%0d beats, first ARLEN=%0d @%0t) AW=%0d (%0d beats, first AWLEN=%0d) W beats=%0d (last @%0t) B=%0d | AP_CTRL reads=%0d idle=0:%0d done=1:%0d | 24-bit truncated beats=%0d",  // 요약
                              name, n_ar[k], ar_beats[k], first_arlen[k], t_first_ar[k], n_aw[k], aw_beats[k], first_awlen[k],  // AR, AW
                              n_w[k], t_last_w[k], n_b[k], n_ctrl_rd[k], n_ctrl_busy[k], n_ctrl_done[k], trunc), UVM_LOW)  // W, B, AP_CTRL
  endfunction                                       // report_step 끝

  // m00 버스를 매 클럭 보고 단계별로 셈
  task bus_watch();                                 // m00 관찰
    virtual axi4_if vif = env.mem_agt.vif;          // m00 interface
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) begin  // AR handshake
        if (n_ar[step] == 0) begin first_arlen[step] = vif.moncb.arlen; t_first_ar[step] = $time; end  // 첫 AR
        n_ar[step]++;                               // 수 증가
        ar_beats[step] += vif.moncb.arlen + 1;      // beat 합
      end                                           // if 끝
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) begin  // AW handshake
        if (n_aw[step] == 0) first_awlen[step] = vif.moncb.awlen;  // 첫 AW
        n_aw[step]++;                               // 수 증가
        aw_beats[step] += vif.moncb.awlen + 1;      // beat 합
      end                                           // if 끝
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) begin  // W handshake
        n_w[step]++;                                // 수 증가
        t_last_w[step] = $time;                     // 시각
      end                                           // if 끝
      if (vif.moncb.bvalid === 1'b1 && vif.moncb.bready === 1'b1) n_b[step]++;  // B handshake
    end                                             // forever 끝
  endtask                                           // bus_watch 끝

  // AXI-Lite를 매 클럭 보고 AP_CTRL 읽기 값(idle, done)을 단계별로 셈 (master는 접근을 하나씩 하므로 마지막 AR과 R을 짝지음)
  task ctl_watch();                                 // AXI-Lite 관찰
    virtual axil_if c = env.ctl_vif;                // 제어 interface
    forever begin                                   // 계속 반복
      @(c.moncb);                                   // 매 클럭 에지
      if (c.moncb.arvalid === 1'b1 && c.moncb.arready === 1'b1) rd_addr = c.moncb.araddr & 12'h03F;  // AR (DUT처럼 [5:0])
      if (c.moncb.rvalid === 1'b1 && c.moncb.rready === 1'b1 && rd_addr == ADDR_AP_CTRL) begin  // AP_CTRL 읽기 R
        n_ctrl_rd[step]++;                          // 수 증가
        if (c.moncb.rdata[AP_IDLE] === 1'b0) n_ctrl_busy[step]++;  // idle=0 (start를 받아 실행 중)
        if (c.moncb.rdata[AP_DONE] === 1'b1) n_ctrl_done[step]++;  // done=1
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // ctl_watch 끝
endclass                                            // 클래스 끝
