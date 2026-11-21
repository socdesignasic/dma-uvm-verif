// dma_aw_wait_after_job_test : H6 가설 확인용 directed test (사양 검사 -> 가설이 맞으면 FAIL)
//   H6: burst 끝에서 is_aw_req_pre가 pop 전 AW FIFO 상태를 봐서 W FSM이 RUN에 남고, AW FIFO가 빈 채
//       4개 전 burst의 길이(stale AWLEN_w)로 W beat를 셈 (wdma.v:465, 486, 506, sync_fifo.v:99)
//   리셋 없음, src/dst 4KB 정렬 (16 beat burst), R/W/B backpressure 없음. AW 대기만 cfg.slv_cfg.aw_fixed_wait를 실행 중에 바꿈
//     S2: job1 64 beat (AW 대기 0) -> job2 64 beat (AW 대기 aw_wait). AW FIFO 4칸이 모두 16이라 stale 16이 우연히 맞음
//     S3: job3 1 beat (AW 대기 0, 칸0 = 1) -> job4 48 beat (칸1~3 = 16, rptr = 0) -> job5 32 beat (AW 대기 aw_wait)
//         가설이 맞으면 job5 첫 W beat부터 WLAST=1 (AXI_WLAST) 뒤 멈춤 (JOB_TIMEOUT)
//   판정은 기존 검사 (AXI_WLAST, scoreboard, predictor, AXI_* SVA, JOB_TIMEOUT). 사양: W가 AW보다 먼저 와도 되고,
//   이력과 무관하게 WLAST는 burst 마지막 beat에만 와야 함
//   버스 관찰 (bus_watch): job마다 AW 대기 최댓값, AW보다 먼저 온 W beat 수, WLAST가 온 beat 번호를 [H6] 줄로 남김.
//   job2, job5에서 AW보다 먼저 온 W beat가 0이면 노린 상태에 가지 못한 것 -> SCENARIO_MISS
//   AW 대기를 0으로 되돌리는 시점: job2 마지막 AW의 대기 둘째 사이클에 bus_watch가 0으로 바꿈. axi4_slave_driver는
//   AWVALID를 본 에지에서 대기 횟수를 한 번 읽어 지역 변수로 쓰므로(실행 중 변경 안전), 이 시점은 job3의 AW 대기를 0으로
//   만들기 위한 것일 뿐 안전 장치가 아님
//   +AW_WAIT=<n> : job2, job5의 AW 대기 사이클 (기본 12. e >= 1이고 매 burst AW가 16 beat 안에 오는 값, trace로 정함)
class dma_aw_wait_after_job_test extends dma_base_test;  // 기본 테스트 상속
  `uvm_component_utils(dma_aw_wait_after_job_test)  // factory 등록
  localparam int unsigned NJ = 5;                   // job 수 (job1..job5)

  int unsigned aw_wait = 12;                        // job2, job5의 AW 대기 사이클 (+AW_WAIT)
  int unsigned cur;                                 // bus_watch가 세는 job 번호 (0이면 아직 없음)
  int unsigned off_job, off_aw;                     // 이 job의 이 번째 AW 대기 중에 aw_fixed_wait를 0으로 (0이면 안 함)
  int unsigned run_wait;                            // 지금 AW의 대기 사이클 (AWVALID && !AWREADY 연속)
  int unsigned n_aw[NJ+1], aw_beats[NJ+1];          // job별 AW 수, AW beat 합
  int unsigned aw_wait_max[NJ+1];                   // job별 AW 하나의 대기 사이클 최댓값
  int unsigned n_w[NJ+1], n_before[NJ+1], n_wlast[NJ+1];  // job별 W beat 수, AW보다 먼저 온 W beat 수, WLAST 수
  string       wlast_at[NJ+1];                      // job별 WLAST=1인 beat 번호 (job 안에서 1부터, 앞 8개)
  time         t_first_w[NJ+1], t_first_aw[NJ+1];   // job별 첫 W beat, 첫 AW handshake 시각
  bit          first_w_last[NJ+1];                  // job별 첫 W beat의 WLAST

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = NJ;                                    // job 5개 (크기와 AW 대기는 run_jobs가 정함)
    if ($value$plusargs("AW_WAIT=%d", aw_wait))     // +AW_WAIT가 있으면
      `uvm_info("TEST", $sformatf("AW_WAIT=%0d (plusarg)", aw_wait), UVM_LOW)  // 덮어쓴 값 로그
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // S2 -> S3
    uvm_report_server svr = uvm_report_server::get_server();  // JOB_TIMEOUT 수를 볼 report server
    if (aw_wait < 3) begin                          // 대기 둘째 사이클에 0으로 바꾸려면 3 이상이어야 함
      `uvm_error("SCENARIO_MISS", $sformatf("AW_WAIT=%0d: must be >= 3 to switch the AW wait off during the last AW of job2", aw_wait))  // 노린 자극을 만들 수 없음
      return;                                       // job을 돌리지 않음
    end                                             // if 끝
    fork bus_watch(); join_none                     // 버스 관찰 시작
    // S2: 정상 작업 뒤 AW 대기
    run_h6_job(1, 64);                              // job1: AW 대기 0 (정상 작업 뒤 W FSM이 RUN에 남는지가 가설)
    cfg.slv_cfg.aw_fixed_wait = aw_wait;            // driver가 대기 없는 쪽을 돌고 있어 다음 AWVALID부터 적용
    off_job = 2; off_aw = 4;                        // job2의 4번째(마지막) AW 대기 중에 0으로
    run_h6_job(2, 64);                              // job2: 첫 burst W beat가 AW보다 먼저 옴
    if (svr.get_id_count("JOB_TIMEOUT") > 0) begin  // job2가 끝나지 않았으면 (중간 리셋이 없어 S3를 돌릴 수 없음)
      `uvm_error("SCENARIO_MISS", "job2 did not finish: S3 (job3..job5) cannot run without a mid-test reset")  // job5 상태에 못 감
      return;                                       // 끝
    end                                             // if 끝
    if (cfg.slv_cfg.aw_fixed_wait != 0) begin       // job2 마지막 AW에서 대기를 끄지 못했으면
      `uvm_error("SCENARIO_MISS", $sformatf("aw_fixed_wait is still %0d after job2 (switch-off point not seen)", cfg.slv_cfg.aw_fixed_wait))  // S3의 AW 대기 0을 만들 수 없음
      return;                                       // 끝
    end                                             // if 끝
    // S3: AW FIFO 칸0에 1 beat 길이를 남긴 뒤 AW 대기
    run_h6_job(3, 1);                               // job3: 1 beat (칸0 = 1)
    run_h6_job(4, 48);                              // job4: 48 beat (칸1~3 = 16, rptr이 칸0으로 돌아옴)
    cfg.slv_cfg.aw_fixed_wait = aw_wait;            // AW 대기 다시 켬 (driver가 대기 없는 쪽이라 안전)
    run_h6_job(5, 32);                              // job5: 가설이 맞으면 stale 1로 첫 beat부터 WLAST=1
    // 노린 상태에 갔는지 (W beat가 AW보다 먼저 와야 W FSM이 AW FIFO가 빈 채로 셈)
    if (n_before[2] == 0) `uvm_error("SCENARIO_MISS", "job2: no W beat before its AW (AW wait too short)")  // job2 미도달
    if (n_before[5] == 0) `uvm_error("SCENARIO_MISS", "job5: no W beat before its AW (AW wait too short)")  // job5 미도달
  endtask                                           // run_jobs 끝

  // H6 job k를 beats beat로 실행. 위치는 1MB 창 k-1의 시작(src)과 512KB 지점(dst), 둘 다 4KB 정렬
  task run_h6_job(int unsigned k, int unsigned beats);  // job 번호, beat 수
    dma_job j = make_job(k - 1);                    // 값과 완료 방식(polling)은 기본 방식
    j.src   = mem_base + (k - 1) * 32'h0010_0000;   // 원본: 창 시작 (4KB 정렬)
    j.dst   = j.src + 32'h0008_0000;                // 대상: 창의 512KB 지점 (4KB 정렬)
    j.bytes = beats * BEAT;                         // 크기
    cur = k;                                        // bus_watch가 이 job으로 셈
    `uvm_info("H6", $sformatf("job%0d: %0d beats, aw_fixed_wait=%0d", k, beats, cfg.slv_cfg.aw_fixed_wait), UVM_LOW)  // 시작 로그
    run_job(j);                                     // 실행 (끝나거나 JOB_TIMEOUT까지)
    `uvm_info("H6", $sformatf("job%0d: AW=%0d (%0d beats, first @%0t, wait max=%0d) W beats=%0d before AW=%0d | first W @%0t WLAST=%0d | WLAST=%0d at beat%s",  // job 요약
                              k, n_aw[k], aw_beats[k], t_first_aw[k], aw_wait_max[k], n_w[k], n_before[k],  // AW, W 수
                              t_first_w[k], first_w_last[k], n_wlast[k], wlast_at[k]), UVM_LOW)  // 첫 W beat, WLAST 위치
  endtask                                           // run_h6_job 끝

  // m00 버스를 매 클럭 보고 job별로 셈. 같은 에지의 AW를 W보다 먼저 셈 (axi4_slave_monitor의 before_aw와 같은 기준)
  task bus_watch();                                 // 버스 관찰
    axi4_vif vif = env.mem_agt.vif;                 // m00 interface
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지
      if (cur == 0) continue;                       // job 전
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready !== 1'b1) begin  // AW 대기 중
        run_wait++;                                 // 대기 사이클 증가
        if (run_wait == 2 && off_job == cur && n_aw[cur] + 1 == off_aw) begin  // 정한 AW의 대기 둘째 사이클 (driver가 대기 횟수를 읽은 뒤)
          cfg.slv_cfg.aw_fixed_wait = 0;            // 이 AW 뒤부터 대기 없음
          off_job = 0;                              // 한 번만
          `uvm_info("H6", $sformatf("aw_fixed_wait -> 0 during AW #%0d of job%0d (wait already counting)", n_aw[cur] + 1, cur), UVM_LOW)  // 바꾼 시점 로그
        end                                         // if 끝
      end                                           // if 끝
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) begin  // AW handshake
        if (n_aw[cur] == 0) t_first_aw[cur] = $time;  // 첫 AW 시각
        if (run_wait > aw_wait_max[cur]) aw_wait_max[cur] = run_wait;  // 대기 최댓값
        run_wait = 0;                               // 다음 AW
        n_aw[cur]++;                                // AW 수 증가
        aw_beats[cur] += vif.moncb.awlen + 1;       // beat 합
      end                                           // if 끝
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) begin  // W handshake
        if (n_w[cur] >= aw_beats[cur]) n_before[cur]++;  // 이 beat 자리의 AW가 아직 없음 -> AW보다 먼저
        if (n_w[cur] == 0) begin                    // 첫 W beat
          t_first_w[cur]    = $time;                // 시각
          first_w_last[cur] = vif.moncb.wlast;      // WLAST
        end                                         // if 끝
        n_w[cur]++;                                 // W beat 수 증가
        if (vif.moncb.wlast === 1'b1) begin         // WLAST beat
          n_wlast[cur]++;                           // 수 증가
          if (n_wlast[cur] <= 8) wlast_at[cur] = {wlast_at[cur], $sformatf(" %0d", n_w[cur])};  // 앞 8개 위치
        end                                         // if 끝
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // bus_watch 끝
endclass                                            // 클래스 끝
