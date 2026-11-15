// axi4_slv_monitor : 받아들인 AR / AW를 모두 axi4_burst로 내보내고,
// DUT가 낼 수 있는 burst인지 검사 (INCR, 8바이트, 정렬, 16 beat 이하, 4KB 경계 넘지 않음)
class axi4_slv_monitor extends uvm_monitor;         // UVM monitor 상속
  `uvm_component_utils(axi4_slv_monitor)            // factory 등록
  axi4_vif     vif;                                 // AXI4 virtual interface 핸들
  axi4_slv_cfg cfg;                                 // 설정 (최대 burst 길이 사용)
  uvm_analysis_port #(axi4_burst) ar_ap, aw_ap;     // AR / AW burst를 내보내는 analysis port

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    ar_ap = new("ar_ap", this);                     // AR port 생성
    aw_ap = new("aw_ap", this);                     // AW port 생성
  endfunction                                       // 생성자 끝

  function void check_burst(axi4_burst b);          // burst 하나가 규칙에 맞는지 검사
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
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1) begin  // AR handshake가 일어났으면
        axi4_burst b = axi4_burst::type_id::create("ar");  // 새 burst 객체 생성
        b.is_write = 0;                             // 읽기로 표시
        b.addr = vif.moncb.araddr; b.len = vif.moncb.arlen;  // 주소와 길이 저장
        b.size = vif.moncb.arsize; b.burst = vif.moncb.arburst; b.t = $time;  // size, burst 종류, 시각 저장
        `uvm_info("AXI_AR", b.convert2string(), UVM_HIGH)  // 상세 로그
        check_burst(b);                             // 규칙 검사
        ar_ap.write(b);                             // 구독자(scoreboard, coverage)에 전달
      end                                           // if 끝
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1) begin  // AW handshake가 일어났으면
        axi4_burst b = axi4_burst::type_id::create("aw");  // 새 burst 객체 생성
        b.is_write = 1;                             // 쓰기로 표시
        b.addr = vif.moncb.awaddr; b.len = vif.moncb.awlen;  // 주소와 길이 저장
        b.size = vif.moncb.awsize; b.burst = vif.moncb.awburst; b.t = $time;  // size, burst 종류, 시각 저장
        `uvm_info("AXI_AW", b.convert2string(), UVM_HIGH)  // 상세 로그
        check_burst(b);                             // 규칙 검사
        aw_ap.write(b);                             // 구독자에 전달
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // run_phase 끝
endclass                                            // 클래스 끝
