// axil_monitor : AXI4-Lite 버스를 관찰해 접근 하나마다 axil_item을 ap로 내보냄 (driver와 따로 동작)
//   쓰기: AW와 W handshake가 모두 끝난 에지에 내보냄 (slave가 레지스터를 바꾸는 에지).
//         이때는 B가 아직 오지 않았으므로 item의 resp는 0이고, B 응답은 아래 검사가 따로 봄
//   읽기: R handshake 에지에 내보냄 (data, resp는 R 채널 값, addr는 짝이 되는 AR 주소)
//   검사: B/R 응답이 OKAY가 아니면 AXIL_RESP (check_resp 한 곳)
//   결함 주입 (inj_rd_*, 기본 꺼짐): checker self-test가 내보내는 읽기 item의 관찰값만 바꿈 (버스와 driver 값은 그대로)
//   테스트 중간 리셋: @(moncb) 뒤 rst_n=0으로 읽히는 에지의 handshake는 보지 않고, 짝이 안 맞은 큐(AW, W, B 대기, R 대기)를 비움
class axil_monitor extends uvm_monitor;             // UVM monitor 상속
  `uvm_component_utils(axil_monitor)                // factory 등록
  axil_vif vif;                                     // AXI4-Lite virtual interface 핸들 (agent가 넣어 줌)
  uvm_analysis_port #(axil_item) ap;                // 관찰한 접근을 내보내는 analysis port

  // 결함 주입 (checker self-test 전용, 기본 꺼짐)
  int unsigned inj_rd_n    = 0;                     // >0이면 주소가 inj_rd_addr인 다음 읽기 이만큼의 data를 inj_rd_xor로 뒤집음 (쓸 때마다 줄임)
  bit [11:0]   inj_rd_addr = 0;                     // 주입할 읽기 주소
  bit [31:0]   inj_rd_xor  = 0;                     // 뒤집을 비트
  int unsigned n_inj;                               // 주입을 실제로 한 수

  bit [11:0] aw_q[$];                               // handshake가 끝났지만 아직 W와 짝짓지 않은 AW 주소
  bit [31:0] wd_q[$];                               // 아직 AW와 짝짓지 않은 W 데이터
  bit [3:0]  ws_q[$];                               // 그 W의 strobe
  bit [11:0] b_q[$];                                // 내보낸 뒤 B를 기다리는 쓰기 주소 (메시지용)
  bit [11:0] ar_q[$];                               // R을 기다리는 읽기 주소
  int unsigned n_wr, n_rd, n_b;                     // 내보낸 쓰기 수, 내보낸 읽기 수, 본 B 수
  int unsigned n_b_orphan, n_r_orphan;              // 짝이 되는 쓰기/AR 없이 온 B, R 수 (요약에만 표시)
  int unsigned n_resets;                            // 본 테스트 중간 리셋 수
  bit          in_reset;                            // 지난 에지가 리셋 에지였는지

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    ap = new("ap", this);                           // analysis port 생성
  endfunction                                       // 생성자 끝

  // B/R 응답 검사 (모든 AXI-Lite 응답이 이 한 곳을 지남)
  function void check_resp(string kind, bit [11:0] addr, bit [1:0] resp);  // kind = "write" 또는 "read"
    if (resp != 2'b00)                              // 응답이 OKAY(0)가 아니면
      `uvm_error("AXIL_RESP", $sformatf("monitor %s 0x%03h: resp=%0d", kind, addr, resp))  // 오류 보고
  endfunction                                       // check_resp 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    @(vif.moncb iff vif.rst_n === 1'b1);            // 리셋이 풀릴 때까지 대기
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지마다 (값은 에지 직전 샘플)
      if (vif.rst_n !== 1'b1) begin                 // 리셋 에지 (해제 에지는 전원 리셋 때처럼 이미 1로 읽힘, top의 dma_reset_if 주석)
        on_reset();                                 // 리셋 처리
        continue;                                   // handshake로 보지 않음
      end                                           // if 끝
      in_reset = 0;                                 // 리셋 아님
      // ---- 쓰기: AW와 W를 따로 모은 뒤 둘 다 있으면 짝지어 내보냄 ----
      if (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1)  // AW handshake
        aw_q.push_back(vif.moncb.awaddr);           // 주소 저장
      if (vif.moncb.wvalid === 1'b1 && vif.moncb.wready === 1'b1) begin  // W handshake
        wd_q.push_back(vif.moncb.wdata);            // 데이터 저장
        ws_q.push_back(vif.moncb.wstrb);            // strobe 저장
      end                                           // if 끝
      while (aw_q.size() > 0 && wd_q.size() > 0) begin  // AW와 W가 모두 끝난 쓰기가 있으면
        axil_item t = axil_item::type_id::create("wr");  // 새 item 생성
        t.write = 1;                                // 쓰기로 표시
        t.addr  = aw_q.pop_front();                 // 주소
        t.data  = wd_q.pop_front();                 // 데이터
        t.strb  = ws_q.pop_front();                 // strobe
        t.resp  = 2'b00;                            // B 전이므로 0 (B는 check_resp가 따로 검사)
        n_wr++;                                     // 쓰기 수 증가
        b_q.push_back(t.addr);                      // B를 기다리는 쓰기로 기록
        `uvm_info("AXIL_MON", t.convert2string(), UVM_HIGH)  // 상세 로그
        ap.write(t);                                // 구독자에 전달
      end                                           // while 끝
      if (vif.moncb.bvalid === 1'b1 && vif.moncb.bready === 1'b1) begin  // B handshake
        bit [11:0] a = 0;                           // 짝이 되는 쓰기 주소
        n_b++;                                      // B 수 증가
        if (b_q.size() > 0) a = b_q.pop_front();    // 가장 오래된 쓰기의 주소
        else n_b_orphan++;                          // 짝이 없으면 요약에서 셈
        check_resp("write", a, vif.moncb.bresp);    // 응답 검사
      end                                           // if 끝
      // ---- 읽기: AR 주소를 모아 두고 R handshake에 내보냄 ----
      if (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1)  // AR handshake
        ar_q.push_back(vif.moncb.araddr);           // 주소 저장
      if (vif.moncb.rvalid === 1'b1 && vif.moncb.rready === 1'b1) begin  // R handshake
        if (ar_q.size() == 0) n_r_orphan++;         // 짝이 되는 AR이 없으면 내보내지 않고 요약에서 셈
        else begin                                  // 짝이 있으면
          axil_item t = axil_item::type_id::create("rd");  // 새 item 생성
          t.write = 0;                              // 읽기로 표시
          t.addr  = ar_q.pop_front();               // 가장 오래된 AR 주소
          t.data  = vif.moncb.rdata;                // 읽은 데이터
          t.resp  = vif.moncb.rresp;                // 응답 코드
          if (inj_rd_n > 0 && t.addr == inj_rd_addr) begin  // 결함 주입 (checker self-test): 관찰값의 비트를 뒤집음
            t.data ^= inj_rd_xor;                   // 뒤집음
            inj_rd_n--;                             // 노브 줄임
            n_inj++;                                // 주입 수 증가
            `uvm_info("AXIL_INJECT", $sformatf("read 0x%03h: observed data 0x%08h -> 0x%08h", t.addr, vif.moncb.rdata, t.data), UVM_LOW)  // 주입 로그
          end                                       // if 끝
          n_rd++;                                   // 읽기 수 증가
          check_resp("read", t.addr, t.resp);       // 응답 검사
          `uvm_info("AXIL_MON", t.convert2string(), UVM_HIGH)  // 상세 로그
          ap.write(t);                              // 구독자에 전달
        end                                         // else 끝
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // run_phase 끝

  // 리셋 에지: 첫 에지에서 짝이 안 맞은 큐를 비움 (리셋 전 AW/W/AR은 리셋 뒤 응답과 짝짓지 않음)
  function void on_reset();                         // 리셋 에지마다 호출
    if (in_reset) return;                           // 이어지는 리셋 에지는 할 일 없음
    in_reset = 1;                                   // 리셋 시작
    n_resets++;                                     // 리셋 수 증가
    `uvm_info("AXIL_RESET", $sformatf("monitor reset #%0d: dropped AW=%0d W=%0d B-wait=%0d R-wait=%0d",  // 진행 로그
                                      n_resets, aw_q.size(), wd_q.size(), b_q.size(), ar_q.size()), UVM_LOW)  // 버린 수
    aw_q.delete(); wd_q.delete(); ws_q.delete();    // 짝짓지 않은 AW, W 비움
    b_q.delete();  ar_q.delete();                   // B, R을 기다리던 접근 비움
  endfunction                                       // on_reset 끝

  // 관찰한 개수 요약 (driver 처리 수와의 비교는 agent의 AXIL_COUNT 줄에서)
  function void report_phase(uvm_phase phase);      // 보고 단계
    `uvm_info("AXIL_MON", $sformatf("observed wr=%0d rd=%0d B=%0d | waiting AW=%0d W=%0d B=%0d R=%0d | orphan B=%0d R=%0d",  // 요약 형식
                                    n_wr, n_rd, n_b, aw_q.size(), wd_q.size(), b_q.size(), ar_q.size(),  // 개수와 남은 큐 크기
                                    n_b_orphan, n_r_orphan), UVM_LOW)  // 짝 없이 온 응답 수
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
