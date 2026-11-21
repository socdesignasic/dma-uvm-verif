// axi4_wb_item : monitor가 본 W beat 하나 또는 B 응답 하나 (is_b로 구분)
//   W beat (w_ap) : data, strb, last, before_aw, t
//   B 응답 (b_ap) : resp, id, t
class axi4_wb_item extends uvm_object;              // UVM object 상속
  `uvm_object_utils(axi4_wb_item)                   // factory 등록
  bit        is_b;                                  // 0 = W beat, 1 = B 응답
  bit [63:0] data;                                  // W 데이터
  bit [7:0]  strb;                                  // W 바이트 strobe
  bit        last;                                  // WLAST
  bit        before_aw;                             // 이 beat를 담을 AW가 아직 handshake되지 않았을 때 온 W beat
  bit [1:0]  resp;                                  // B 응답 코드
  bit [0:0]  id;                                    // B ID
  time       t;                                     // handshake가 일어난 시뮬레이션 시각

  function new(string name = "axi4_wb_item");       // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual function string convert2string();         // 로그용 문자열 변환
    if (is_b) return $sformatf("B resp=%0d id=%0d @%0t", resp, id, t);  // B: 응답 코드, ID, 시각
    return $sformatf("W data=0x%016h strb=0x%02h last=%0d%s @%0t",  // W: 데이터, strobe, last, 시각
                     data, strb, last, before_aw ? " (before AW)" : "", t);  // AW보다 먼저 왔으면 표시
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
