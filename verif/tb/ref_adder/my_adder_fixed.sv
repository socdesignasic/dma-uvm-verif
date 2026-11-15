// -----------------------------------------------------------------------------
// uvm_reference/design.sv를 고친 사본 (P0 "통과 경로" 확인용).
// 참고 코드의 버그: 리셋 극성이 반대 (rstn==1, 즉 리셋이 아닐 때
// 출력이 0으로 고정됨). scoreboard는 그 반대를 기대함.
// -----------------------------------------------------------------------------
module my_adder (adder_if _if);
  always_comb begin
    if (!_if.rstn) begin
      _if.sum   = '0;
      _if.carry = 1'b0;
    end else begin
      {_if.carry, _if.sum} = _if.a + _if.b;
    end
  end
endmodule
