// axil_reg_adapter : uvm_reg 접근 <-> axil_item 변환 (RAL frontdoor와 uvm_reg_predictor가 씀)
//   reg2bus : RAL 읽기/쓰기 하나를 axil_item으로 (strobe는 항상 4바이트 전부)
//   bus2reg : driver가 처리한 item 또는 axil_monitor가 본 item을 RAL 접근으로 (resp != 0이면 UVM_NOT_OK)
class axil_reg_adapter extends uvm_reg_adapter;     // UVM 레지스터 adapter 상속
  `uvm_object_utils(axil_reg_adapter)               // factory 등록

  function new(string name = "axil_reg_adapter");   // 생성자
    super.new(name);                                // 부모 생성자 호출
    supports_byte_enable = 0;                       // driver는 strobe를 늘 4'hF로 보냄
    provides_responses   = 0;                       // driver가 같은 item에 data/resp를 채움 (따로 응답 없음)
  endfunction                                       // 생성자 끝

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);  // RAL 접근 -> bus item
    axil_item t = axil_item::type_id::create("t");  // 새 item 생성
    t.write = (rw.kind == UVM_WRITE);               // 쓰기 여부
    t.addr  = rw.addr[11:0];                        // 주소 (12비트)
    t.data  = rw.data[31:0];                        // 쓰기 데이터 (읽기면 driver가 덮어씀)
    return t;                                       // item 돌려줌
  endfunction                                       // reg2bus 끝

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);  // bus item -> RAL 접근
    axil_item t;                                    // 변환할 item
    if (!$cast(t, bus_item))                        // axil_item이 아니면 (연결 실수)
      `uvm_fatal("ADAPTER", "bus_item is not an axil_item")  // 바로 중단
    rw.kind    = t.write ? UVM_WRITE : UVM_READ;    // 읽기/쓰기
    rw.addr    = t.addr;                            // 주소
    rw.data    = t.data;                            // 쓴 값 또는 읽은 값
    rw.byte_en = t.strb;                            // 바이트 strobe (읽기 item은 기본값 4'hF)
    rw.status  = (t.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;  // 응답 코드 -> 상태
  endfunction                                       // bus2reg 끝
endclass                                            // 클래스 끝
