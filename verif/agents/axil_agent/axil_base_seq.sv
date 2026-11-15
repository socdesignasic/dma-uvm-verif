// axil_base_seq : AXI4-Lite agent에서 레지스터를 다루는 sequence의 기본 클래스
//   write_reg(addr, data)  /  read_reg(addr, data)
// 응답이 OKAY가 아니면 UVM_ERROR로 보고합니다.
class axil_base_seq extends uvm_sequence #(axil_item);  // axil_item을 다루는 UVM sequence 상속
  `uvm_object_utils(axil_base_seq)                  // factory 등록

  function new(string name = "axil_base_seq");      // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  task write_reg(bit [11:0] addr, bit [31:0] data);  // 레지스터 쓰기 태스크
    axil_item t = axil_item::type_id::create("wr");  // 쓰기 item 생성
    start_item(t);                                  // sequencer에 item 요청
    t.write = 1;                                    // 쓰기로 표시
    t.addr  = addr;                                 // 주소 설정
    t.data  = data;                                 // 데이터 설정
    finish_item(t);                                 // driver로 보내고 끝날 때까지 대기
    if (t.resp != 2'b00)                            // 응답이 OKAY(0)가 아니면
      `uvm_error("AXIL_RESP", $sformatf("write 0x%03h: resp=%0d", addr, t.resp))  // 오류 보고
  endtask                                           // write_reg 끝

  task read_reg(bit [11:0] addr, output bit [31:0] data);  // 레지스터 읽기 태스크 (결과는 data로)
    axil_item t = axil_item::type_id::create("rd");  // 읽기 item 생성
    start_item(t);                                  // sequencer에 item 요청
    t.write = 0;                                    // 읽기로 표시
    t.addr  = addr;                                 // 주소 설정
    finish_item(t);           // item_done 전에 driver가 data/resp를 채움
    data = t.data;                                  // driver가 채운 읽은 값을 돌려줌
    if (t.resp != 2'b00)                            // 응답이 OKAY가 아니면
      `uvm_error("AXIL_RESP", $sformatf("read 0x%03h: resp=%0d", addr, t.resp))  // 오류 보고
  endtask                                           // read_reg 끝
endclass                                            // 클래스 끝
