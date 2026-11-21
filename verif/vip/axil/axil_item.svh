// axil_item : AXI4-Lite 읽기 또는 쓰기 하나 (읽기는 driver가 data/resp를 채움)
class axil_item extends uvm_sequence_item;          // UVM sequence item 상속
  rand bit        write;                            // 1 = 쓰기, 0 = 읽기
  rand bit [11:0] addr;                             // 레지스터 주소 (12비트)
  rand bit [31:0] data;                             // 쓰기 데이터 또는 읽은 데이터
  bit      [3:0]  strb = 4'hF;                      // 바이트 strobe (항상 4바이트 전부)
  bit      [1:0]  resp;                             // 응답 코드 (0 = OKAY)

  `uvm_object_utils_begin(axil_item)                // factory 등록과 필드 자동화 시작
    `uvm_field_int(write, UVM_ALL_ON)               // write 필드 (출력/비교/복사 대상)
    `uvm_field_int(addr,  UVM_ALL_ON)               // addr 필드
    `uvm_field_int(data,  UVM_ALL_ON)               // data 필드
    `uvm_field_int(resp,  UVM_ALL_ON)               // resp 필드
  `uvm_object_utils_end                             // 필드 자동화 끝

  function new(string name = "axil_item");          // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual function string convert2string();         // 로그용 문자열 변환
    return $sformatf("%s addr=0x%03h data=0x%08h resp=%0d", write ? "WR" : "RD", addr, data, resp);  // WR/RD, 주소, 데이터, 응답을 한 줄로
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
