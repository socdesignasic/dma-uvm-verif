// axil_driver : AXI4-Lite master. 쓰기: AW와 W를 보낸 뒤 B. 읽기: AR 뒤 R.
//   타이밍 노브 (cfg = axil_cfg, 기본 0이면 노브를 넣기 전과 사이클 단위로 같고 $urandom을 부르지 않음):
//     max_aw_w_skew > 0   : 쓰기마다 AW/W 순서를 고름. 같은 사이클 / AW 먼저 d 에지 / W 먼저 d 에지 (d = 1..max_aw_w_skew)
//     max_ready_delay > 0 : B/R 응답마다 d = 0..max_ready_delay. d > 0이면 READY를 내린 채 VALID를 본 에지부터
//                           d 에지 동안 기다린 뒤 READY를 올림 (d = 0이면 기본처럼 VALID 전에 미리 올림)
//   AXI 규칙: master VALID는 ready를 기다리지 않고 올리며(간격은 정해진 에지 수) handshake까지 유지하고,
//             READY는 VALID를 본 뒤에 올려도 됨. slave VALID 유지는 axil_if의 SVA가 검사
//   리셋: driver는 접근 도중의 리셋을 처리하지 않음 (B/R 대기에서 멈춤). 노브가 0이면 접근 중 master 신호 하나가 늘 1이라
//         리셋하는 쪽이 끝을 알 수 있지만, 노브를 켜면 그렇지 않으므로 노브를 켠 채 테스트 중간 리셋은 지원하지 않음 (axil_cfg)
class axil_driver extends uvm_driver #(axil_item);  // axil_item을 받는 UVM driver 상속
  `uvm_component_utils(axil_driver)                 // factory 등록
  axil_vif vif;                                     // AXI4-Lite virtual interface 핸들
  axil_cfg cfg;                                     // 타이밍 노브 (agent가 넣어 줌, 없으면 run_phase에서 기본값)
  int unsigned n_wr, n_rd;                          // 처리한 쓰기 수, 읽기 수 (agent 요약에서 monitor와 비교)
  int unsigned n_aw_first, n_w_first;               // AWVALID를 먼저 낸 쓰기 수, WVALID를 먼저 낸 쓰기 수 (skew 노브)
  int unsigned n_b_late, n_r_late;                  // BREADY를 늦게 올린 쓰기 수, RREADY를 늦게 올린 읽기 수 (ready 노브)

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    if (cfg == null) cfg = axil_cfg::type_id::create("cfg");  // 노브를 받지 못했으면 기본값 (0)
    vif.awvalid <= 0; vif.wvalid <= 0; vif.bready <= 0;  // 쓰기 쪽 valid/ready 초기화
    vif.arvalid <= 0; vif.rready <= 0;              // 읽기 쪽 valid/ready 초기화
    vif.awaddr  <= 0; vif.wdata  <= 0; vif.wstrb  <= 0; vif.araddr <= 0;  // 주소, 데이터, strobe 초기화
    @(vif.cb iff vif.rst_n === 1'b1);               // 리셋이 풀릴 때까지 대기
    forever begin                                   // 계속 반복
      seq_item_port.get_next_item(req);             // sequencer에서 다음 item 받기
      if (req.write) begin do_write(req); n_wr++; end  // 쓰기면 do_write 후 쓰기 수 증가
      else           begin do_read(req);  n_rd++; end  // 읽기면 do_read 후 읽기 수 증가
      `uvm_info("AXIL", req.convert2string(), UVM_HIGH)  // 상세 로그
      seq_item_port.item_done();                    // item 처리 완료 알림
    end                                             // forever 끝
  endtask                                           // run_phase 끝

  // AW와 W를 각자 정한 에지 수(기본 0 = 같은 사이클) 뒤에 내보내고, 각각 자기 handshake에서 끝남. 그다음 B
  task do_write(axil_item t);                       // 쓰기 트랜잭션 태스크
    int unsigned aw_wait = 0, w_wait = 0;           // AWVALID, WVALID를 올리기 전에 기다리는 에지 수
    if (cfg.max_aw_w_skew > 0) pick_skew(aw_wait, w_wait);  // 노브가 켜졌을 때만 순서와 간격을 고름
    fork                                            // AW와 W를 병렬로
      begin                                         // AW 채널
        repeat (aw_wait) @(vif.cb);                 // W 먼저면 그만큼 늦게
        vif.cb.awvalid <= 1; vif.cb.awaddr <= t.addr;  // AWVALID와 주소 구동
        do @(vif.cb); while (vif.cb.awready !== 1'b1);  // AWREADY를 기다림
        vif.cb.awvalid <= 0;                        // AWVALID 내림
      end                                           // AW 채널 끝
      begin                                         // W 채널
        repeat (w_wait) @(vif.cb);                  // AW 먼저면 그만큼 늦게
        vif.cb.wvalid <= 1; vif.cb.wdata <= t.data; vif.cb.wstrb <= t.strb;  // WVALID, 데이터, strobe 구동
        do @(vif.cb); while (vif.cb.wready !== 1'b1);  // WREADY를 기다림
        vif.cb.wvalid <= 0;                         // WVALID 내림
      end                                           // W 채널 끝
    join                                            // 둘 다 끝날 때까지 대기
    ready_delay(1'b1);                              // (노브) BREADY를 내린 채 BVALID를 보고 기다림
    vif.cb.bready <= 1;                             // B 응답 받을 준비
    do @(vif.cb); while (vif.cb.bvalid !== 1'b1);   // BVALID가 1이 될 때까지 대기
    t.resp = vif.cb.bresp;                          // 응답 코드 저장
    vif.cb.bready <= 0;                             // BREADY 내림
  endtask                                           // do_write 끝

  task do_read(axil_item t);                        // 읽기 트랜잭션 태스크
    vif.cb.arvalid <= 1; vif.cb.araddr <= t.addr;   // ARVALID와 주소 구동
    do @(vif.cb); while (vif.cb.arready !== 1'b1);  // ARREADY가 1이 될 때까지 대기
    vif.cb.arvalid <= 0;                            // ARVALID 내림
    ready_delay(1'b0);                              // (노브) RREADY를 내린 채 RVALID를 보고 기다림
    vif.cb.rready  <= 1;                            // R 데이터 받을 준비
    do @(vif.cb); while (vif.cb.rvalid !== 1'b1);   // RVALID가 1이 될 때까지 대기
    t.data = vif.cb.rdata;                          // 읽은 데이터 저장
    t.resp = vif.cb.rresp;                          // 응답 코드 저장
    vif.cb.rready <= 0;                             // RREADY 내림
  endtask                                           // do_read 끝

  // 쓰기 하나의 AW/W 순서와 간격 (max_aw_w_skew > 0일 때만 부름): 같은 사이클 / AW 먼저 / W 먼저 (각 1/3), 간격 1..max 에지
  function void pick_skew(output int unsigned aw_wait, output int unsigned w_wait);  // AW, W 앞 대기 에지 수
    int unsigned order, d;                          // 순서 (0 같은 사이클, 1 AW 먼저, 2 W 먼저), 간격
    order   = $urandom_range(2, 0);                 // 순서
    d       = $urandom_range(cfg.max_aw_w_skew, 1); // 간격
    aw_wait = 0;  w_wait = 0;                       // 기본: 같은 사이클
    if (order == 1) begin w_wait  = d; n_aw_first++; end  // AW 먼저: W를 d 에지 늦게
    if (order == 2) begin aw_wait = d; n_w_first++;  end  // W 먼저: AW를 d 에지 늦게
  endfunction                                       // pick_skew 끝

  // READY 지연 (max_ready_delay > 0일 때만 난수): d > 0이면 READY=0인 채 VALID를 본 에지부터 d 에지째까지 기다림.
  //   부르는 쪽이 이어서 READY를 올리므로 handshake는 그다음 에지 (VALID가 READY 없이 d 에지 동안 유지됨). d = 0이면 아무것도 안 함
  task ready_delay(bit is_b);                       // B(1) 또는 R(0)
    int unsigned d = 0;                             // 늦출 에지 수
    if (cfg.max_ready_delay > 0) d = $urandom_range(cfg.max_ready_delay, 0);  // 노브가 켜졌을 때만
    if (d == 0) return;                             // 기본: 미리 올림
    if (is_b) begin                                 // B
      n_b_late++;                                   // 늦춘 쓰기 응답 수
      do @(vif.cb); while (vif.cb.bvalid !== 1'b1); // BREADY=0인 채 BVALID를 봄 (첫 에지)
    end else begin                                  // R
      n_r_late++;                                   // 늦춘 읽기 응답 수
      do @(vif.cb); while (vif.cb.rvalid !== 1'b1); // RREADY=0인 채 RVALID를 봄 (첫 에지)
    end                                             // if 끝
    repeat (d - 1) @(vif.cb);                       // 나머지 d-1 에지
  endtask                                           // ready_delay 끝

  // 노브를 켰을 때만 실제로 늦춘 수를 남김 (기본 설정의 로그는 노브를 넣기 전과 같음)
  function void report_phase(uvm_phase phase);      // 보고 단계
    if (cfg != null && (cfg.max_aw_w_skew > 0 || cfg.max_ready_delay > 0))  // 노브를 켰으면
      `uvm_info("AXIL_TIMING", $sformatf("%s | writes=%0d (AW first=%0d, W first=%0d) B late=%0d | reads=%0d R late=%0d",  // 요약
                                         cfg.convert2string(), n_wr, n_aw_first, n_w_first, n_b_late, n_rd, n_r_late), UVM_LOW)  // 값들
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
