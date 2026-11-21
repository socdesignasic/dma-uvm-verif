// axi4_slave_driver : m00의 slave 쪽을 구동하고 axi4_mem에서 읽고 씀
//
//   ar_channel -> ar_q -> r_channel
//   aw_channel -> aw_q -.
//   w_channel  -> w_q  -+-> write_engine -> b_q -> b_channel
//   결함 주입 (cfg.inj_*, 기본 꺼짐): checker self-test가 R 데이터나 쓰기 주소를 일부러 틀리게 만들 때만 씀
//   테스트 중간 리셋: rst_n이 0이 되면 채널 thread 6개를 모두 끝내고 ready/valid를 0으로, 큐를 비움 (메모리는 그대로).
//         리셋이 풀린 뒤 첫 에지(전원 리셋 때와 같은 에지)에서 thread를 다시 시작
class axi4_slave_driver extends uvm_component;        // UVM component 상속 (sequence 없이 스스로 반응)
  `uvm_component_utils(axi4_slave_driver)             // factory 등록
  axi4_vif     vif;                                 // AXI4 virtual interface 핸들
  axi4_slave_cfg cfg;                                 // slave 동작 설정
  axi4_mem     mem;                                 // 읽고 쓸 메모리 모델

  axi4_item ar_q[$], aw_q[$], b_q[$];              // 받은 AR, 받은 AW, B 응답 대기 burst 큐
  bit [63:0] w_data_q[$];                           // 받은 W 데이터 큐
  bit [7:0]  w_strb_q[$];                           // 받은 W strobe 큐
  bit        w_last_q[$];                           // 받은 W last 표시 큐
  int unsigned n_rd_beats, n_wr_beats, n_rd_uninit;  // 읽은 beat 수, 쓴 beat 수, 초기화 안 된 읽기 수
  int unsigned n_inj;                               // 결함 주입을 실제로 한 수 (checker self-test, 보통 0)
  int unsigned n_resets;                            // 처리한 테스트 중간 리셋 수 (전원 리셋 제외)

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
    forever begin                                   // 리셋마다
      @(vif.cb iff vif.rst_n === 1'b1);             // 리셋이 풀릴 때까지 대기
      // 채널 6개를 예전과 같은 순서로 병렬 시작하고, 리셋 감시는 이 process가 함 (감시용 process를 따로 만들지 않음)
      fork                                          // 채널 thread
        ar_channel();                               // AR 수락
        r_channel();                                // R 데이터 응답
        aw_channel();                               // AW 수락
        w_channel();                                // W 데이터 수락
        write_engine();                             // AW와 W를 짝지어 메모리에 쓰기
        b_channel();                                // B 응답
      join_none                                     // 기다리지 않음 (모두 forever)
      wait (vif.rst_n !== 1'b1);                    // 리셋 감시: rst_n이 0이 된 시각 (그 에지의 채널 처리는 이미 끝남)
      disable fork;                                 // 채널 thread 모두 끝냄 (이 run_phase process의 자식만)
      bus_reset();                                  // 출력 0, 큐 비움
    end                                             // forever 끝
  endtask                                           // run_phase 끝

  // 리셋: ready/valid를 0으로, 처리 중이던 burst와 beat를 버림. 메모리와 결함 주입 노브는 그대로
  //   출력은 clocking block으로 구동: 끝낸 thread가 같은 에지에 걸어 둔 구동(에지 +skew에 반영)보다 나중이라 이 값이 이김
  task bus_reset();                                 // rst_n이 0이 된 시각에 부름
    vif.cb.awready <= 0; vif.cb.wready <= 0; vif.cb.arready <= 0;  // ready 모두 0
    vif.cb.bvalid  <= 0; vif.cb.rvalid <= 0; vif.cb.rlast  <= 0;   // valid와 RLAST 0
    n_resets++;                                     // 리셋 수 증가
    `uvm_info("AXI_RESET", $sformatf("bus reset #%0d: dropped AR=%0d AW=%0d W beats=%0d B=%0d (memory kept)",  // 진행 로그
                                     n_resets, ar_q.size(), aw_q.size(), w_data_q.size(), b_q.size()), UVM_LOW)  // 버린 수
    ar_q.delete(); aw_q.delete(); b_q.delete();     // burst 큐 비움
    w_data_q.delete(); w_strb_q.delete(); w_last_q.delete();  // W beat 큐 비움
  endtask                                           // bus_reset 끝

  // ---------------- 읽기 경로 ----------------
  task ar_channel();                                // AR 채널 처리 태스크
    bit rdy;                                        // 이번 사이클 ARREADY 값
    forever begin                                   // 계속 반복
      rdy = pick(cfg.ar_ready_pct);                 // 설정 확률로 ARREADY 결정
      vif.cb.arready <= rdy;                        // ARREADY 구동
      @(vif.cb);                                    // 다음 클럭 에지까지 대기
      if (rdy && vif.cb.arvalid === 1'b1) begin     // READY와 VALID가 모두 1이면 handshake 성립
        axi4_item b = axi4_item::type_id::create("ar");  // 새 burst 객체 생성
        b.is_write = 0;                             // 읽기 burst로 표시
        b.addr = vif.cb.araddr; b.len = vif.cb.arlen;  // 주소와 길이 저장
        b.size = vif.cb.arsize; b.burst = vif.cb.arburst; b.t = $time;  // size, burst 종류, 시각 저장
        ar_q.push_back(b);                          // R 채널이 처리하도록 큐에 넣음
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // ar_channel 끝

  task r_channel();                                 // R 채널 처리 태스크
    axi4_item b;                                   // 처리 중인 AR burst
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
        inject_r(b, i, d);                          // 결함 주입 (checker self-test, 노브가 0이면 아무것도 안 함)
        vif.cb.rvalid <= 1; vif.cb.rdata <= d; vif.cb.rlast <= (i == b.beats() - 1);  // RVALID, 데이터, 마지막 beat 표시 구동
        vif.cb.rresp  <= 0; vif.cb.rid   <= 0;      // 응답 OKAY, ID 0
        do @(vif.cb); while (vif.cb.rready !== 1'b1);  // RREADY가 1이 될 때까지 대기 (handshake)
        n_rd_beats++;                               // 읽은 beat 수 증가
      end                                           // for 끝
      vif.cb.rvalid <= 0;                           // burst가 끝나면 RVALID 내림
      vif.cb.rlast  <= 0;                           // RLAST 내림
    end                                             // forever 끝
  endtask                                           // r_channel 끝

  // 결함 주입 (checker self-test 전용): 이번 R beat 데이터 d를 일부러 틀리게 만듦. cfg 노브가 모두 0이면 아무것도 안 함
  //   inj_r_flip : 비트 하나를 뒤집음
  //   inj_r_addr : 같은 burst 안 이웃 beat(다음 beat, 마지막이면 앞 beat)의 데이터를 줌.
  //                이웃이 초기화돼 있고 값이 다를 때만 하고, 아니면 다음 beat에서 다시 시도
  function void inject_r(axi4_item b, int i, inout bit [63:0] d);  // burst, beat 번호, 데이터
    bit [63:0]   alt;                               // 이웃 beat 데이터
    bit [31:0]   a2;                                // 이웃 beat 주소
    int unsigned k;                                 // 뒤집을 비트
    if (cfg.inj_r_flip > 0) begin                   // 비트 뒤집기
      k = $urandom_range(63);                       // 비트 위치
      d[k] = ~d[k];                                 // 뒤집음
      cfg.inj_r_flip--;                             // 노브 줄임
      n_inj++;                                      // 주입 수 증가
      `uvm_info("AXI_INJECT", $sformatf("R beat @0x%08h: data bit %0d flipped (%s)", b.addr + i * 8, k, b.convert2string()), UVM_LOW)  // 주입 로그
    end                                             // if 끝
    if (cfg.inj_r_addr > 0 && b.beats() > 1) begin  // 다른 주소 읽기 (이웃이 있는 burst만)
      a2 = (i + 1 < b.beats()) ? b.addr + (i + 1) * 8 : b.addr + (i - 1) * 8;  // 같은 burst 안 이웃 beat
      if (mem.rd64(a2, alt) && alt != d) begin      // 초기화돼 있고 값이 다르면
        d = alt;                                    // 이웃 데이터를 줌
        cfg.inj_r_addr--;                           // 노브 줄임
        n_inj++;                                    // 주입 수 증가
        `uvm_info("AXI_INJECT", $sformatf("R beat @0x%08h: data read from 0x%08h instead (%s)", b.addr + i * 8, a2, b.convert2string()), UVM_LOW)  // 주입 로그
      end                                           // if 끝
    end                                             // if 끝
  endfunction                                       // inject_r 끝

  // ---------------- 쓰기 경로 ----------------
  // aw_fixed_wait는 테스트가 실행 중에 바꿀 수 있음: AWVALID를 본 순간의 값을 한 번만 읽어 지역 변수로 씀
  //   (기다리는 동안 0으로 바뀌면 이 AW는 더 기다리지 않고 받음. 예전처럼 다시 읽어 0 - 1 = 2^32-1번 기다리지 않음)
  task aw_channel();                                // AW 채널 처리 태스크
    bit          rdy;                               // 이번 사이클 AWREADY 값
    int unsigned wait_n;                            // 이번 AW의 고정 대기 사이클 수
    forever begin                                   // 계속 반복
      if (cfg.aw_fixed_wait > 0) begin       // 정해진 사이클만큼 AW를 멈춤
        vif.cb.awready <= 0;                        // AWREADY를 0으로
        do @(vif.cb); while (vif.cb.awvalid !== 1'b1);  // AWVALID가 올라올 때까지 대기
        wait_n = cfg.aw_fixed_wait;                 // 이 AW의 대기 (한 번만 읽음)
        if (wait_n > 1) repeat (wait_n - 1) @(vif.cb);  // 남은 대기 사이클만큼 더 기다림 (0이나 1이면 바로)
        rdy = 1;                                    // 그다음 사이클에 수락
      end else                                      // 고정 대기가 없으면
        rdy = pick(cfg.aw_ready_pct);               // 설정 확률로 AWREADY 결정
      vif.cb.awready <= rdy;                        // AWREADY 구동
      @(vif.cb);                                    // 다음 클럭 에지까지 대기
      if (rdy && vif.cb.awvalid === 1'b1) begin     // handshake 성립 확인
        axi4_item b = axi4_item::type_id::create("aw");  // 새 burst 객체 생성
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
    axi4_item b;                                   // 처리 중인 AW burst
    bit last;                                       // 이번 beat의 WLAST
    bit [31:0] shift;                               // 결함 주입: 쓰는 주소를 미는 바이트 수 (보통 0)
    forever begin                                   // 계속 반복
      while (aw_q.size() == 0) @(vif.cb);           // AW가 생길 때까지 대기
      b = aw_q.pop_front();                         // 가장 오래된 AW 꺼냄
      shift = 0;                                    // 기본: 주소 그대로
      if (cfg.inj_w_shift_end != 0 && b.end_addr() == cfg.inj_w_shift_end) begin  // 결함 주입 (checker self-test): 이 burst를 밀어 씀
        shift = 8;                                  // +8B
        cfg.inj_w_shift_end = 0;                    // 한 번만
        n_inj++;                                    // 주입 수 증가
        `uvm_info("AXI_INJECT", $sformatf("write burst shifted by +8B: %s", b.convert2string()), UVM_LOW)  // 주입 로그
      end                                           // if 끝
      for (int i = 0; i < b.beats(); i++) begin     // burst의 beat마다
        while (w_data_q.size() == 0) @(vif.cb);     // W beat가 생길 때까지 대기
        last = w_last_q.pop_front();                // WLAST 꺼냄
        if (last != (i == b.beats() - 1))           // WLAST가 마지막 beat 여부와 다르면
          `uvm_error("AXI_WLAST", $sformatf("WLAST=%0d on beat %0d of %0d (%s)",  // 오류 보고
                                            last, i, b.beats(), b.convert2string()))  // 오류 메시지에 넣을 값들
        mem.wr64(b.addr + shift + i * 8, w_data_q.pop_front(), w_strb_q.pop_front());  // 데이터를 strobe에 맞춰 메모리에 씀 (shift는 결함 주입 때만 0이 아님)
      end                                           // for 끝
      b_q.push_back(b);                             // B 응답 대기 큐에 넣음
    end                                             // forever 끝
  endtask                                           // write_engine 끝

  task b_channel();                                 // B 채널 처리 태스크
    axi4_item    b;                                // 응답할 burst
    int unsigned lo, hi;                            // 이번 B의 지연 하한, 상한 (cfg를 한 번만 읽음, 실행 중 변경 안전)
    forever begin                                   // 계속 반복
      while (b_q.size() == 0) @(vif.cb);            // 응답할 burst가 생길 때까지 대기
      b = b_q.pop_front();                          // 가장 오래된 것 꺼냄
      lo = cfg.min_b_latency;  hi = cfg.max_b_latency;  // 하한, 상한
      if (hi < lo) hi = lo;                         // 상한이 하한보다 작으면 하한으로 고정 ($urandom_range의 맞바꿈 대신)
      repeat ($urandom_range(hi, lo)) @(vif.cb);    // 랜덤 지연 (lo..hi. lo=0이면 예전 $urandom_range(max, 0)과 같은 난수)
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
