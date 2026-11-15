// axi4_mem : 희소(sparse) 바이트 메모리 (연관 배열이라 쓴 주소만 존재)
//   has(a) : 주소 a에 쓴 적이 있는가?   rd8(a) : 주소 a의 바이트, 쓴 적 없으면 0
class axi4_mem extends uvm_object;
  `uvm_object_utils(axi4_mem)
  bit [7:0] m[bit [31:0]];

  function new(string name = "axi4_mem");
    super.new(name);
  endfunction

  function void wr8(bit [31:0] a, bit [7:0] d);  m[a] = d;  endfunction
  function bit      has(bit [31:0] a);           return m.exists(a); endfunction
  function bit [7:0] rd8(bit [31:0] a);          return m.exists(a) ? m[a] : 8'h00; endfunction

  // beat의 모든 바이트가 초기화돼 있으면 1을 반환
  function bit rd64(bit [31:0] a, output bit [63:0] d);
    bit ok = 1;
    for (int i = 0; i < 8; i++) begin
      ok &= m.exists(a + i);
      d[i*8 +: 8] = rd8(a + i);
    end
    return ok;
  endfunction

  function void wr64(bit [31:0] a, bit [63:0] d, bit [7:0] strb);
    for (int i = 0; i < 8; i++)
      if (strb[i]) m[a + i] = d[i*8 +: 8];
  endfunction
endclass
