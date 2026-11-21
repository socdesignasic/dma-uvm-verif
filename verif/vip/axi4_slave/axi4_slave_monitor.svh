// axi4_slave_monitor : 받아들인 AR / AW를 모두 axi4_item로 내보내고,
// DUT가 낼 수 있는 burst인지 검사 (INCR, 8바이트, 정렬, 16 beat 이하, 4KB 경계 넘지 않음)
// W beat와 B 응답도 handshake마다 axi4_wb_item로 내보냄 (w_ap / b_ap, 검사 없음).
// driver의 큐는 읽지 않고 버스만 봄. W가 AW보다 먼저 와도 그대로 내보냄 (before_aw 표시).
// 테스트 중간 리셋: @(moncb) 뒤 rst_n=0으로 읽히는 에지의 handshake는 보지 않음. 리셋의 첫 에지에서 aw_beats = n_w로 맞춰
//   짝 없이 남은 AW beat(또는 AW 없이 온 W)를 버림. 리셋 뒤 W는 리셋 뒤 AW와만 짝지어 before_aw를 판단
class axi4_slave_monitor extends uvm_monitor;         // UVM monitor 상속
  `uvm_component_utils(axi4_slave_monitor)            // factory 등록
  axi4_vif     vif;                                 // AXI4 virtual interface 핸들
  axi4_slave_cfg cfg;                                 // 설정 (최대 burst 길이 사용)
  uvm_analysis_port #(axi4_item) ar_ap, aw_ap;     // AR / AW burst를 내보내는 analysis port
  uvm_analysis_port #(axi4_wb_item) w_ap, b_ap;     // W beat / B 응답을 내보내는 analysis port
  int unsigned n_ar, n_aw, n_w, n_w_last, n_w_before_aw, n_b;  // 본 AR, AW, W beat, WLAST beat, AW보다 먼저 온 W beat, B 수
  longint unsigned aw_beats;                        // 지금까지 본 AW의 beat 합 (W beat가 AW보다 먼저 왔는지 판단)
  int unsigned n_resets;                            // 본 테스트 중간 리셋 수
  bit          in_reset;                            // 지난 에지가 리셋 에지였는지

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    ar_ap = new("ar_ap", this);                     // AR port 생성
    aw_ap = new("aw_ap", this);                     // AW port 생성
    w_ap  = new("w_ap", this);                      // W port 생성
    b_ap  = new("b_ap", this);                      // B port 생성
  endfunction                                       // 생성자 끝

  function void check_burst(axi4_item b);          // burst 하나가 규칙에 맞는지 검사
    if (b.burst != 2'b01)                           // burst 종류가 INCR(1)이 아니면
      `uvm_error("AXI_BURST", {"burst type is not INCR: ", b.convert2string()})  // 오류 보고
    if (b.size != 3'd3)                             // size가 8바이트(3)가 아니면
      `uvm_error("AXI_SIZE", {"size is not 8 bytes: ", b.convert2string()})  // 오류 보고
    if (b.addr[2:0] != 0)                           // 주소 하위 3비트가 0이 아니면 (정렬 안 됨)
      `uvm_error("AXI_ALIGN", {"address not 8-byte aligned: ", b.convert2string()})  // 오류 보고
    if (b.beats() > cfg.max_burst_len)              // beat 수가 최대값보다 크면
      `uvm_error("AXI_LEN", {"burst longer than 16 beats: ", b.convert2string()})  // 오류 보고
    if ((b.addr & 32'hFFF) + b.beats() * 8 > 32'h1000)  // 4KB 페이지 안 위치 + 길이가 4KB를 넘으면
      `uvm_error("AXI_4KB", {"burst crosses a 4KB boundary: ", b.convert2string()})  // 오류 보고
  endfunction                                       // check_burst 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    @(vif.moncb iff vif.rst_n === 1'b1);            // 리셋이 풀릴 때까지 대기
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지마다
      if (vif.rst_n !== 1'b1) begin                 // 리셋 에지 (해제 에지는 전원 리셋 때처럼 이미 1로 읽힘, dma_reset_if 주석)
        on_reset();                                 // 리셋 처리
        continue;                                   // handshake로 보지 않음
      end                                           // if 끝
      in_reset = 0;                                 // 리셋 아님
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) begin  // AR handshake가 일어났으면
        axi4_item b = axi4_item::type_id::create("ar");  // 새 burst 객체 생성
        b.is_write = 0;                             // 읽기로 표시
        b.addr = vif.moncb.araddr; b.len = vif.moncb.arlen;  // 주소와 길이 저장
        b.size = vif.moncb.arsize; b.burst = vif.moncb.arburst; b.t = $time;  // size, burst 종류, 시각 저장
        n_ar++;                                     // AR 수 증가
        `uvm_info("AXI_AR", b.convert2string(), UVM_HIGH)  // 상세 로그
        check_burst(b);                             // 규칙 검사
        ar_ap.write(b);                             // 구독자(scoreboard, coverage)에 전달
      end                                           // if 끝
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) begin  // AW handshake가 일어났으면
        axi4_item b = axi4_item::type_id::create("aw");  // 새 burst 객체 생성
        b.is_write = 1;                             // 쓰기로 표시
        b.addr = vif.moncb.awaddr; b.len = vif.moncb.awlen;  // 주소와 길이 저장
        b.size = vif.moncb.awsize; b.burst = vif.moncb.awburst; b.t = $time;  // size, burst 종류, 시각 저장
        n_aw++;  aw_beats += b.beats();             // AW 수와 beat 합 증가
        `uvm_info("AXI_AW", b.convert2string(), UVM_HIGH)  // 상세 로그
        check_burst(b);                             // 규칙 검사
        aw_ap.write(b);                             // 구독자에 전달
      end                                           // if 끝
      // 같은 에지의 AW를 먼저 처리했으므로, 같은 에지에 온 AW와 W는 "AW보다 먼저"가 아님
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) begin  // W handshake가 일어났으면
        axi4_wb_item w = axi4_wb_item::type_id::create("w");  // 새 W beat 객체 생성
        w.is_b = 0;                                 // W beat로 표시
        w.data = vif.moncb.wdata; w.strb = vif.moncb.wstrb; w.last = vif.moncb.wlast;  // 데이터, strobe, last 저장
        w.t = $time;                                // 시각 저장
        w.before_aw = (n_w >= aw_beats);            // 지금까지 본 AW가 이 beat 자리를 아직 만들지 않았으면 AW보다 먼저 온 것
        n_w++;                                      // W beat 수 증가
        if (w.last)      n_w_last++;                // WLAST beat 수 증가
        if (w.before_aw) n_w_before_aw++;           // AW보다 먼저 온 beat 수 증가
        `uvm_info("AXI_W_MON", w.convert2string(), UVM_DEBUG)  // beat마다 상세 로그 (양이 많아 DEBUG)
        w_ap.write(w);                              // 구독자에 전달
      end                                           // if 끝
      if (vif.moncb.bvalid === 1'b1 && vif.moncb.bready === 1'b1) begin  // B handshake가 일어났으면
        axi4_wb_item r = axi4_wb_item::type_id::create("b");  // 새 B 응답 객체 생성
        r.is_b = 1;                                 // B 응답으로 표시
        r.resp = vif.moncb.bresp; r.id = vif.moncb.bid; r.t = $time;  // 응답 코드, ID, 시각 저장
        n_b++;                                      // B 수 증가
        `uvm_info("AXI_B_MON", r.convert2string(), UVM_HIGH)  // 상세 로그
        b_ap.write(r);                              // 구독자에 전달
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // run_phase 끝

  // 리셋 에지: 첫 에지에서만 W/AW 짝 맞춤을 처음부터 (aw_beats = n_w)
  function void on_reset();                         // 리셋 에지마다 호출
    if (in_reset) return;                           // 이어지는 리셋 에지는 할 일 없음
    in_reset = 1;                                   // 리셋 시작
    n_resets++;                                     // 리셋 수 증가
    `uvm_info("AXI_RESET", $sformatf("monitor reset #%0d: unmatched AW-W beats=%0d dropped (AW beats=%0d, W beats=%0d)",  // 진행 로그
                                     n_resets, longint'(aw_beats) - longint'(n_w), aw_beats, n_w), UVM_LOW)  // 짝 없이 남은 beat 수
    aw_beats = n_w;                                 // 남은 AW beat(또는 AW 없이 온 W)를 버림
  endfunction                                       // on_reset 끝

  // 관찰한 개수 요약 (driver 수와의 비교는 agent의 AXI_COUNT 줄에서)
  function void report_phase(uvm_phase phase);      // 보고 단계
    `uvm_info("AXI_MON", $sformatf("observed AR=%0d AW=%0d (%0d beats) W beats=%0d (WLAST=%0d, before AW=%0d) B=%0d",  // 요약 형식
                                   n_ar, n_aw, aw_beats, n_w, n_w_last, n_w_before_aw, n_b), UVM_LOW)  // 채널별 개수
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
