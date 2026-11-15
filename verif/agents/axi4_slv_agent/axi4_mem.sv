// axi4_mem : 희소(sparse) 바이트 메모리 (연관 배열이라 쓴 주소만 존재)
//   has(a) : 주소 a에 쓴 적이 있는가?   rd8(a) : 주소 a의 바이트, 쓴 적 없으면 0
class axi4_mem extends uvm_object;                  // UVM object로 만든 메모리 모델
  `uvm_object_utils(axi4_mem)                       // factory 등록
  bit [7:0] m[bit [31:0]];                          // 주소 -> 바이트 연관 배열 (쓴 주소만 저장)

  function new(string name = "axi4_mem");           // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void wr8(bit [31:0] a, bit [7:0] d);  m[a] = d;  endfunction  // 바이트 하나 쓰기
  function bit      has(bit [31:0] a);           return m.exists(a); endfunction  // 해당 주소가 쓰인 적 있는지 확인
  function bit [7:0] rd8(bit [31:0] a);          return m.exists(a) ? m[a] : 8'h00; endfunction  // 바이트 하나 읽기 (없으면 0)

  // beat의 모든 바이트가 초기화돼 있으면 1을 반환
  function bit rd64(bit [31:0] a, output bit [63:0] d);  // 8바이트 beat 읽기, 결과는 d로 돌려줌
    bit ok = 1;                                     // 모든 바이트가 초기화됐는지 표시 (처음엔 1)
    for (int i = 0; i < 8; i++) begin               // beat 안의 바이트 8개를 차례로
      ok &= m.exists(a + i);                        // 하나라도 없으면 ok = 0
      d[i*8 +: 8] = rd8(a + i);                     // i번째 바이트를 d의 해당 위치에 넣음
    end                                             // for 끝
    return ok;                                      // 초기화 여부 반환
  endfunction                                       // rd64 끝

  function void wr64(bit [31:0] a, bit [63:0] d, bit [7:0] strb);  // 8바이트 beat 쓰기 (strobe가 1인 바이트만)
    for (int i = 0; i < 8; i++)                     // 바이트 8개를 차례로
      if (strb[i]) m[a + i] = d[i*8 +: 8];          // strobe 비트가 1이면 그 바이트를 저장
  endfunction                                       // wr64 끝
endclass                                            // 클래스 끝
