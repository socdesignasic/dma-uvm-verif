// dma_slow_b_test : H7 가설 확인용 directed test (사양 검사 -> 가설이 맞으면 FAIL)
//   H7: B 응답이 W burst보다 느리면 W->B FIFO(깊이 4)가 찬 채 burst가 끝나(is_aw_req_pre의 w_fifo_full_n도 push 전 값)
//       B 항목이 버려지고, W FSM이 IDLE로 가서 다음 beat를 세지 않아 WLAST 오류와 멈춤이 생김 (wdma.v:465, 537, 568, sync_fifo.v:114)
//   자극: 512 beat job 하나 (src/dst 4KB 정렬 -> 16 beat burst 32개), AR/AW/W ready 100%, R 지연 0, B 지연 0..60 (max_b_latency).
//         slave는 B를 하나씩 순서대로 지연해 주므로 B 처리 간격(평균 약 30사이클)이 W burst 간격(16사이클)보다 김
//   사양: B 지연에는 제한이 없고 master는 미해결 쓰기를 잃으면 안 됨 -> 기존 검사(AXI_WLAST, scoreboard, predictor,
//         AXI_* SVA, JOB_TIMEOUT)가 그대로 판정. 검사를 바꾸지 않음
//   버스 관찰 (bus_watch): 미해결 burst 수(WLAST handshake 수 - B handshake 수)를 매 클럭 세어 최댓값을 [H7] max outstanding으로 남김.
//   MIN_OUTSTANDING 미만이면 W->B FIFO가 차는 상태(FIFO 4 + B FSM 1)에 가지 못한 것 -> SCENARIO_MISS
class dma_slow_b_test extends dma_base_test;        // 기본 테스트 상속
  `uvm_component_utils(dma_slow_b_test)             // factory 등록
  localparam int unsigned MIN_OUTSTANDING = 5;      // 노린 상태: W->B FIFO 4칸 + B FSM이 붙든 1개

  int unsigned n_wlast, n_b;                        // 본 WLAST handshake 수, B handshake 수
  int unsigned max_out;                             // 미해결 burst 수 최댓값
  time         t_max;                               // 최댓값에 처음 닿은 시각

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 1; min_beats = 512; max_beats = 512;   // 512 beat job 하나
    cfg.slv_cfg.ar_ready_pct  = 100;                // ARREADY 항상 1
    cfg.slv_cfg.aw_ready_pct  = 100;                // AWREADY 항상 1
    cfg.slv_cfg.w_ready_pct   = 100;                // WREADY 항상 1
    cfg.slv_cfg.max_r_latency = 0;                  // R 첫 beat 지연 없음
    cfg.slv_cfg.r_gap_pct     = 0;                  // R 사이 빈 사이클 없음
    cfg.slv_cfg.max_b_latency = 60;                 // 마지막 W -> BVALID 0..60사이클
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // job 하나 + 버스 관찰
    dma_job j = make_job(0);                        // 값과 완료 방식(polling)은 기본 방식
    j.src   = mem_base;                             // 원본: 창 0 시작 (4KB 정렬)
    j.dst   = mem_base + 32'h0008_0000;             // 대상: 창 0의 512KB 지점 (4KB 정렬)
    j.bytes = max_beats * BEAT;                     // 512 beat = 4KB 한 페이지 = 16 beat burst 32개
    fork bus_watch(); join_none                     // 버스 관찰 시작
    run_job(j);                                     // 실행 (끝나거나 JOB_TIMEOUT까지)
    `uvm_info("H7", $sformatf("max outstanding=%0d (first @%0t) | WLAST hs=%0d B hs=%0d",  // 요약
                              max_out, t_max, n_wlast, n_b), UVM_LOW)  // 최댓값, 시각, 수
    if (max_out < MIN_OUTSTANDING)                  // 노린 상태에 못 감
      `uvm_error("SCENARIO_MISS", $sformatf("max outstanding bursts %0d < %0d: W->B FIFO never filled", max_out, MIN_OUTSTANDING))  // 판정 불가
  endtask                                           // run_jobs 끝

  // m00 버스를 매 클럭 보고 미해결 burst 수(WLAST hs - B hs)를 셈. 새 최댓값이 4 이상이면 시각을 남김 (trace 구간용)
  task bus_watch();                                 // 버스 관찰
    axi4_vif vif = env.mem_agt.vif;                 // m00 interface
    int      out;                                   // 지금 미해결 burst 수
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1 && vif.moncb.wlast === 1'b1) n_wlast++;  // WLAST handshake
      if (vif.moncb.bvalid === 1'b1 && vif.moncb.bready === 1'b1) n_b++;  // B handshake
      out = int'(n_wlast) - int'(n_b);              // 미해결 burst 수
      if (out > int'(max_out)) begin                // 새 최댓값
        max_out = out;                              // 기록
        t_max   = $time;                            // 시각
        if (max_out >= MIN_OUTSTANDING - 1)         // 노린 상태 근처부터 로그
          `uvm_info("H7", $sformatf("outstanding bursts reached %0d (WLAST hs=%0d B hs=%0d)", max_out, n_wlast, n_b), UVM_LOW)  // 도달 시각 (trace 구간용)
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // bus_watch 끝
endclass                                            // 클래스 끝
