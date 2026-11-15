// axi4_burst : 받아들인 AR 또는 AW 요청 하나
class axi4_burst extends uvm_object;                // UVM object를 상속한 burst 정보 클래스
  `uvm_object_utils(axi4_burst)                     // factory 등록 (type_id::create로 만들 수 있게)
  bit        is_write;                              // 1 = 쓰기(AW), 0 = 읽기(AR)
  bit [31:0] addr;                                  // burst 시작 주소
  bit [7:0]  len;      // beat 수 - 1
  bit [2:0]  size;                                  // beat 크기 코드 (3 = 8바이트)
  bit [1:0]  burst;                                 // burst 종류 (1 = INCR)
  time       t;                                     // handshake가 일어난 시뮬레이션 시각

  function new(string name = "axi4_burst");         // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function int unsigned beats(); return len + 1; endfunction  // beat 수 = len + 1
  function bit [31:0] end_addr(); return addr + beats() * 8; endfunction  // 끝 주소 (이 주소는 포함하지 않음)

  virtual function string convert2string();         // 로그용 문자열 변환
    return $sformatf("%s addr=0x%08h len=%0d (%0d beats) size=%0d burst=%0d",  // AW/AR, 주소, 길이, size, burst를 한 줄로
                     is_write ? "AW" : "AR", addr, len, beats(), size, burst);  // 형식 문자열에 넣을 값들
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
