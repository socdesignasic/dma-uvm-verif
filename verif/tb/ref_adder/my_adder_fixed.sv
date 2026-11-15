// -----------------------------------------------------------------------------
// uvm_reference/design.sv를 고친 사본 (P0 "통과 경로" 확인용).
// 참고 코드의 버그: 리셋 극성이 반대 (rstn==1, 즉 리셋이 아닐 때
// 출력이 0으로 고정됨). scoreboard는 그 반대를 기대함.
// -----------------------------------------------------------------------------
module my_adder (adder_if _if);                     // adder 모듈 (인터페이스 하나로 연결)
  always_comb begin                                 // 조합 논리
    if (!_if.rstn) begin                            // 리셋 중이면 (rstn = 0)
      _if.sum   = '0;                               // 합 0
      _if.carry = 1'b0;                             // carry 0
    end else begin                                  // 리셋이 아니면
      {_if.carry, _if.sum} = _if.a + _if.b;         // a + b를 계산해 carry와 합으로 나눔
    end                                             // if 끝
  end                                               // always_comb 끝
endmodule                                           // 모듈 끝
