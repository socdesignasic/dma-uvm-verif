// axil_driver : AXI4-Lite master. 쓰기: AW와 W를 함께 보낸 뒤 B. 읽기: AR 뒤 R.
class axil_driver extends uvm_driver #(axil_item);  // axil_item을 받는 UVM driver 상속
  `uvm_component_utils(axil_driver)                 // factory 등록
  axil_vif vif;                                     // AXI4-Lite virtual interface 핸들
  int unsigned n_wr, n_rd;                          // 처리한 쓰기 수, 읽기 수 (agent 요약에서 monitor와 비교)

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
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

  // AW와 W를 동시에 내보내고, 각각 자기 handshake에서 끝남
  task do_write(axil_item t);                       // 쓰기 트랜잭션 태스크
    vif.cb.awvalid <= 1; vif.cb.awaddr <= t.addr;   // AWVALID와 주소 구동
    vif.cb.wvalid  <= 1; vif.cb.wdata  <= t.data; vif.cb.wstrb <= t.strb;  // WVALID, 데이터, strobe 구동
    fork                                            // AW와 W handshake를 병렬로 기다림
      begin do @(vif.cb); while (vif.cb.awready !== 1'b1); vif.cb.awvalid <= 0; end  // AWREADY를 기다린 뒤 AWVALID 내림
      begin do @(vif.cb); while (vif.cb.wready  !== 1'b1); vif.cb.wvalid  <= 0; end  // WREADY를 기다린 뒤 WVALID 내림
    join                                            // 둘 다 끝날 때까지 대기
    vif.cb.bready <= 1;                             // B 응답 받을 준비
    do @(vif.cb); while (vif.cb.bvalid !== 1'b1);   // BVALID가 1이 될 때까지 대기
    t.resp = vif.cb.bresp;                          // 응답 코드 저장
    vif.cb.bready <= 0;                             // BREADY 내림
  endtask                                           // do_write 끝

  task do_read(axil_item t);                        // 읽기 트랜잭션 태스크
    vif.cb.arvalid <= 1; vif.cb.araddr <= t.addr;   // ARVALID와 주소 구동
    do @(vif.cb); while (vif.cb.arready !== 1'b1);  // ARREADY가 1이 될 때까지 대기
    vif.cb.arvalid <= 0;                            // ARVALID 내림
    vif.cb.rready  <= 1;                            // R 데이터 받을 준비
    do @(vif.cb); while (vif.cb.rvalid !== 1'b1);   // RVALID가 1이 될 때까지 대기
    t.data = vif.cb.rdata;                          // 읽은 데이터 저장
    t.resp = vif.cb.rresp;                          // 응답 코드 저장
    vif.cb.rready <= 0;                             // RREADY 내림
  endtask                                           // do_read 끝
endclass                                            // 클래스 끝
