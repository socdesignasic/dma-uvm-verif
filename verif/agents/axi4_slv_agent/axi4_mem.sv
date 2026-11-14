// axi4_mem : sparse byte memory (associative array, only written addresses exist)
//   has(a) : was address a ever written?   rd8(a) : byte at a, 0 if never written
class axi4_mem extends uvm_object;
  `uvm_object_utils(axi4_mem)
  bit [7:0] m[bit [31:0]];

  function new(string name = "axi4_mem");
    super.new(name);
  endfunction

  function void wr8(bit [31:0] a, bit [7:0] d);  m[a] = d;  endfunction
  function bit      has(bit [31:0] a);           return m.exists(a); endfunction
  function bit [7:0] rd8(bit [31:0] a);          return m.exists(a) ? m[a] : 8'h00; endfunction

  // returns 1 if every byte of the beat was initialised
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
