// axi4_slv_driver : m00의 slave 쪽을 구동하고 axi4_mem에서 읽고 씀
//
//   ar_channel -> ar_q -> r_channel
//   aw_channel -> aw_q -.
//   w_channel  -> w_q  -+-> write_engine -> b_q -> b_channel
class axi4_slv_driver extends uvm_component;        // UVM component 상속 (sequence 없이 스스로 반응)
  `uvm_component_utils(axi4_slv_driver)             // factory 등록
  axi4_vif     vif;                                 // AXI4 virtual interface 핸들
  axi4_slv_cfg cfg;                                 // slave 동작 설정
  axi4_mem     mem;                                 // 읽고 쓸 메모리 모델

  axi4_burst ar_q[$], aw_q[$], b_q[$];              // 받은 AR, 받은 AW, B 응답 대기 burst 큐
  bit [63:0] w_data_q[$];                           // 받은 W 데이터 큐
  bit [7:0]  w_strb_q[$];                           // 받은 W strobe 큐
  bit        w_last_q[$];                           // 받은 W last 표시 큐
  int unsigned n_rd_beats, n_wr_beats, n_rd_uninit;  // 읽은 beat 수, 쓴 beat 수, 초기화 안 된 읽기 수

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function bit pick(int unsigned pct);              // pct% 확률로 1을 돌려주는 도우미
    return $urandom_range(99) < pct;                // 0..99 난수가 pct보다 작으면 1
  endfunction                                       // pick 끝

  virtual task run_phase(uvm_phase phase);          // 시뮬레이션 동안 계속 도는 run 단계
    vif.awready <= 0; vif.wready <= 0; vif.arready <= 0;  // ready 신호를 모두 0으로 초기화
    vif.bvalid  <= 0; vif.bresp  <= 0; vif.bid    <= 0;  // B 채널 출력 초기화
    vif.rvalid  <= 0; vif.rdata  <= 0; vif.rlast  <= 0; vif.rresp <= 0; vif.rid <= 0;  // R 채널 출력 초기화
    @(vif.cb iff vif.rst_n === 1'b1);               // 리셋이 풀릴 때까지 대기
    fork                                            // 채널 6개를 병렬로 실행
      ar_channel();                                 // AR 수락
      r_channel();                                  // R 데이터 응답
      aw_channel();                                 // AW 수락
      w_channel();                                  // W 데이터 수락
      write_engine();                               // AW와 W를 짝지어 메모리에 쓰기
      b_channel();                                  // B 응답
    join                                            // fork 끝 (모두 forever라 끝나지 않음)
  endtask                                           // run_phase 끝

  // ---------------- 읽기 경로 ----------------
  task ar_channel();                                // AR 채널 처리 태스크
    bit rdy;                                        // 이번 사이클 ARREADY 값
    forever begin                                   // 계속 반복
      rdy = pick(cfg.ar_ready_pct);                 // 설정 확률로 ARREADY 결정
      vif.cb.arready <= rdy;                        // ARREADY 구동
      @(vif.cb);                                    // 다음 클럭 에지까지 대기
      if (rdy && vif.cb.arvalid === 1'b1) begin     // READY와 VALID가 모두 1이면 handshake 성립
        axi4_burst b = axi4_burst::type_id::create("ar");  // 새 burst 객체 생성
        b.is_write = 0;                             // 읽기 burst로 표시
        b.addr = vif.cb.araddr; b.len = vif.cb.arlen;  // 주소와 길이 저장
        b.size = vif.cb.arsize; b.burst = vif.cb.arburst; b.t = $time;  // size, burst 종류, 시각 저장
        ar_q.push_back(b);                          // R 채널이 처리하도록 큐에 넣음
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // ar_channel 끝

  task r_channel();                                 // R 채널 처리 태스크
    axi4_burst b;                                   // 처리 중인 AR burst
    bit [63:0] d;                                   // 이번 beat 데이터
    forever begin                                   // 계속 반복
      while (ar_q.size() == 0) @(vif.cb);           // 처리할 AR이 생길 때까지 대기
      b = ar_q.pop_front();                         // 가장 오래된 AR 꺼냄
      repeat ($urandom_range(cfg.max_r_latency, 0)) @(vif.cb);  // 첫 beat 전 랜덤 지연 (0..max_r_latency)
      for (int i = 0; i < b.beats(); i++) begin     // burst의 beat마다
        while (pick(cfg.r_gap_pct)) begin           // 설정 확률로 빈 사이클을 넣음
          vif.cb.rvalid <= 0;                       // 빈 사이클 동안 RVALID = 0
          @(vif.cb);                                // 한 사이클 대기
        end                                         // while 끝
        if (!mem.rd64(b.addr + i * 8, d)) begin     // 메모리에서 beat 읽기, 초기화 안 됐으면
          n_rd_uninit++;                            // 초기화 안 된 읽기 수 증가
          `uvm_error("AXI_RD_UNINIT", $sformatf("read of uninitialised memory at 0x%08h (%s)",  // 오류 보고 (주소 포함)
                                                 b.addr + i * 8, b.convert2string()))  // 오류 메시지에 넣을 주소와 burst 정보
        end                                         // if 끝
        vif.cb.rvalid <= 1; vif.cb.rdata <= d; vif.cb.rlast <= (i == b.beats() - 1);  // RVALID, 데이터, 마지막 beat 표시 구동
        vif.cb.rresp  <= 0; vif.cb.rid   <= 0;      // 응답 OKAY, ID 0
        do @(vif.cb); while (vif.cb.rready !== 1'b1);  // RREADY가 1이 될 때까지 대기 (handshake)
        n_rd_beats++;                               // 읽은 beat 수 증가
      end                                           // for 끝
      vif.cb.rvalid <= 0;                           // burst가 끝나면 RVALID 내림
      vif.cb.rlast  <= 0;                           // RLAST 내림
    end                                             // forever 끝
  endtask                                           // r_channel 끝

  // ---------------- 쓰기 경로 ----------------
  task aw_channel();                                // AW 채널 처리 태스크
    bit rdy;                                        // 이번 사이클 AWREADY 값
    forever begin                                   // 계속 반복
      if (cfg.aw_fixed_wait > 0) begin       // 정해진 사이클만큼 AW를 멈춤
        vif.cb.awready <= 0;                        // AWREADY를 0으로
        do @(vif.cb); while (vif.cb.awvalid !== 1'b1);  // AWVALID가 올라올 때까지 대기
        repeat (cfg.aw_fixed_wait - 1) @(vif.cb);   // 남은 대기 사이클만큼 더 기다림
        rdy = 1;                                    // 그다음 사이클에 수락
      end else                                      // 고정 대기가 없으면
        rdy = pick(cfg.aw_ready_pct);               // 설정 확률로 AWREADY 결정
      vif.cb.awready <= rdy;                        // AWREADY 구동
      @(vif.cb);                                    // 다음 클럭 에지까지 대기
      if (rdy && vif.cb.awvalid === 1'b1) begin     // handshake 성립 확인
        axi4_burst b = axi4_burst::type_id::create("aw");  // 새 burst 객체 생성
        b.is_write = 1;                             // 쓰기 burst로 표시
        b.addr = vif.cb.awaddr; b.len = vif.cb.awlen;  // 주소와 길이 저장
        b.size = vif.cb.awsize; b.burst = vif.cb.awburst; b.t = $time;  // size, burst 종류, 시각 저장
        aw_q.push_back(b);                          // write_engine이 처리하도록 큐에 넣음
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // aw_channel 끝

  task w_channel();                                 // W 채널 처리 태스크
    bit rdy;                                        // 이번 사이클 WREADY 값
    forever begin                                   // 계속 반복
      rdy = pick(cfg.w_ready_pct);                  // 설정 확률로 WREADY 결정
      vif.cb.wready <= rdy;                         // WREADY 구동
      @(vif.cb);                                    // 다음 클럭 에지까지 대기
      if (rdy && vif.cb.wvalid === 1'b1) begin      // handshake 성립 확인
        w_data_q.push_back(vif.cb.wdata);           // 데이터 저장
        w_strb_q.push_back(vif.cb.wstrb);           // strobe 저장
        w_last_q.push_back(vif.cb.wlast);           // last 표시 저장
        n_wr_beats++;                               // 쓴 beat 수 증가
        `uvm_info("AXI_W", $sformatf("W beat #%0d last=%0d (AW pending=%0d)",  // 디버그 로그 (beat 번호, last, 대기 중인 AW 수)
                                     n_wr_beats, vif.cb.wlast, aw_q.size()), UVM_DEBUG)  // 로그에 넣을 값들
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // w_channel 끝

  // AW 하나와 그 W beat들을 순서대로 짝지음
  task write_engine();                              // 쓰기 처리 태스크
    axi4_burst b;                                   // 처리 중인 AW burst
    bit last;                                       // 이번 beat의 WLAST
    forever begin                                   // 계속 반복
      while (aw_q.size() == 0) @(vif.cb);           // AW가 생길 때까지 대기
      b = aw_q.pop_front();                         // 가장 오래된 AW 꺼냄
      for (int i = 0; i < b.beats(); i++) begin     // burst의 beat마다
        while (w_data_q.size() == 0) @(vif.cb);     // W beat가 생길 때까지 대기
        last = w_last_q.pop_front();                // WLAST 꺼냄
        if (last != (i == b.beats() - 1))           // WLAST가 마지막 beat 여부와 다르면
          `uvm_error("AXI_WLAST", $sformatf("WLAST=%0d on beat %0d of %0d (%s)",  // 오류 보고
                                            last, i, b.beats(), b.convert2string()))  // 오류 메시지에 넣을 값들
        mem.wr64(b.addr + i * 8, w_data_q.pop_front(), w_strb_q.pop_front());  // 데이터를 strobe에 맞춰 메모리에 씀
      end                                           // for 끝
      b_q.push_back(b);                             // B 응답 대기 큐에 넣음
    end                                             // forever 끝
  endtask                                           // write_engine 끝

  task b_channel();                                 // B 채널 처리 태스크
    axi4_burst b;                                   // 응답할 burst
    forever begin                                   // 계속 반복
      while (b_q.size() == 0) @(vif.cb);            // 응답할 burst가 생길 때까지 대기
      b = b_q.pop_front();                          // 가장 오래된 것 꺼냄
      repeat ($urandom_range(cfg.max_b_latency, 0)) @(vif.cb);  // 랜덤 지연 (0..max_b_latency)
      vif.cb.bvalid <= 1; vif.cb.bresp <= 0; vif.cb.bid <= 0;  // BVALID 올리고 응답 OKAY, ID 0
      do @(vif.cb); while (vif.cb.bready !== 1'b1);  // BREADY가 1이 될 때까지 대기
      vif.cb.bvalid <= 0;                           // BVALID 내림
    end                                             // forever 끝
  endtask                                           // b_channel 끝

  // 테스트가 끝날 때 처리 중인 것이 남아 있으면 안 됨
  function void check_phase(uvm_phase phase);       // 시뮬레이션 끝의 검사 단계
    if (ar_q.size() || aw_q.size() || b_q.size() || w_data_q.size())  // 큐에 남은 것이 있으면
      `uvm_error("AXI_PENDING", $sformatf("pending at end: AR=%0d AW=%0d W beats=%0d B=%0d",  // 오류 보고
                                          ar_q.size(), aw_q.size(), w_data_q.size(), b_q.size()))  // 각 큐의 남은 개수
  endfunction                                       // check_phase 끝
endclass                                            // 클래스 끝
