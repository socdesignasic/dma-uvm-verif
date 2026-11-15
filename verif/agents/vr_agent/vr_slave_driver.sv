// vr_slave_driver : 랜덤 backpressure와 가끔 긴 stall을 넣어 ready 구동
class vr_slave_driver extends uvm_component;        // UVM component 상속 (sequence 없이 스스로 구동)
  `uvm_component_utils(vr_slave_driver)             // factory 등록
  vr_vif vif;                                       // virtual interface 핸들
  vr_cfg cfg;                                       // agent 설정

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    vif.ready <= 1'b0;                              // ready 초기화
    @(vif.scb iff !vif.rst);                        // 리셋이 풀릴 때까지 대기
    forever begin                                   // 계속 반복
      if (cfg.max_stall > 0 && $urandom_range(99) < cfg.stall_pct) begin  // stall 설정이 있고 stall_pct 확률에 걸리면
        vif.scb.ready <= 1'b0;                      // ready 내림
        repeat ($urandom_range(cfg.max_stall, 1)) @(vif.scb);  // 1..max_stall 사이클 동안 유지
      end else begin                                // stall이 아니면
        vif.scb.ready <= ($urandom_range(99) < cfg.ready_pct);  // ready_pct 확률로 ready 결정
        @(vif.scb);                                 // 한 사이클 대기
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // run_phase 끝
endclass                                            // 클래스 끝
