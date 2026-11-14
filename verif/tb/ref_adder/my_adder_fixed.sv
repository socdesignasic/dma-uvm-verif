// -----------------------------------------------------------------------------
// Corrected copy of uvm_reference/design.sv (P0 "pass path" check).
// Reference bug: reset polarity is inverted (outputs forced to 0 while
// rstn==1, i.e. while NOT in reset). The scoreboard expects the opposite.
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
