// stream_source_driver : sequence item으로 valid/data/side를 구동하고 ready까지 유지
class stream_source_driver extends uvm_driver #(stream_item);  // stream_item을 받는 UVM driver 상속
  `uvm_component_utils(stream_source_driver)            // factory 등록
  stream_vif vif;                                       // virtual interface 핸들
  stream_cfg cfg;                                       // agent 설정

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    vif.valid <= 1'b0;                              // valid 초기화
    vif.data  <= '0;                                // data 초기화
    vif.side  <= '0;                                // side 초기화
    @(vif.mcb iff !vif.rst);                        // 리셋이 풀릴 때까지 대기
    repeat (cfg.post_reset_idle) @(vif.mcb);        // 설정된 사이클만큼 더 쉼
    forever begin                                   // 계속 반복
      seq_item_port.get_next_item(req);             // sequencer에서 다음 item 받기
      repeat (req.delay) @(vif.mcb);                // item이 정한 사이클만큼 쉼
      vif.mcb.valid <= 1'b1;                        // valid 올림
      vif.mcb.data  <= req.data;                    // data 구동
      vif.mcb.side  <= req.side;                    // side 구동
      do @(vif.mcb); while (vif.mcb.ready !== 1'b1);  // ready가 1이 될 때까지 대기 (handshake)
      vif.mcb.valid <= 1'b0;     // back-to-back이면 같은 step에서 다시 덮어씀
      seq_item_port.item_done();                    // item 처리 완료 알림
    end                                             // forever 끝
  endtask                                           // run_phase 끝
endclass                                            // 클래스 끝
