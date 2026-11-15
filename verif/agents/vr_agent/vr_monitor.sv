// vr_monitor : valid&&ready handshake마다 vr_item 하나를 내보냄
class vr_monitor extends uvm_monitor;               // UVM monitor 상속
  `uvm_component_utils(vr_monitor)                  // factory 등록
  vr_vif vif;                                       // virtual interface 핸들
  uvm_analysis_port #(vr_item) ap;                  // 본 beat를 내보내는 analysis port

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    ap = new("ap", this);                           // analysis port 생성
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    forever begin                                   // 계속 반복
      @(vif.moncb);                                 // 매 클럭 에지마다
      if (vif.moncb.rst !== 1'b0) continue;         // 리셋 중이면 건너뜀
      if (vif.moncb.valid === 1'b1 && vif.moncb.ready === 1'b1) begin  // valid와 ready가 모두 1이면
        vr_item t = vr_item::type_id::create("t");  // 새 item 생성
        t.data = vif.moncb.data;                    // 데이터 저장
        t.side = vif.moncb.side;                    // sideband 저장
        `uvm_info("VR_MON", t.convert2string(), UVM_HIGH)  // 상세 로그
        ap.write(t);                                // 구독자(scoreboard, coverage)에 전달
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // run_phase 끝
endclass                                            // 클래스 끝
