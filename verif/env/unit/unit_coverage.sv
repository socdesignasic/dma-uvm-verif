// unit_coverage : beat 값(경계값, carry) + 사이클별 handshake 상태
class unit_coverage extends uvm_component;
  `uvm_component_utils(unit_coverage)
  uvm_analysis_imp #(vr_item, unit_coverage) in_imp;
  vr_vif in_vif, out_vif;

  bit [63:0] d;
  bit [31:0] s;
  bit        lo_carry, hi_carry;
  bit [1:0]  in_st, out_st;   // {valid, ready}

  covergroup cg_beat;
    option.per_instance = 1;
    cp_lo   : coverpoint d[31:0]  { bins zero = {0}; bins max = {32'hFFFF_FFFF};
                                    bins msb  = {32'h8000_0000};
                                    bins other = {[1:32'h7FFF_FFFF], [32'h8000_0001:32'hFFFF_FFFE]}; }
    cp_hi   : coverpoint d[63:32] { bins zero = {0}; bins max = {32'hFFFF_FFFF};
                                    bins msb  = {32'h8000_0000};
                                    bins other = {[1:32'h7FFF_FFFF], [32'h8000_0001:32'hFFFF_FFFE]}; }
    cp_side : coverpoint s        { bins zero = {0}; bins one = {1}; bins max = {32'hFFFF_FFFF};
                                    bins other = {[2:32'hFFFF_FFFE]}; }
    // carry는 write()에서 계산: XSim은 coverpoint 식 안의 폭 변환(cast)을 잘못 계산함
    cp_lo_carry : coverpoint lo_carry { bins no = {0}; bins yes = {1}; }
    cp_hi_carry : coverpoint hi_carry { bins no = {0}; bins yes = {1}; }
  endgroup

  // 사이클별 handshake 상태: 00 idle, 01 ready만, 10 stall, 11 전송
  covergroup cg_cycle;
    option.per_instance = 1;
    cp_in      : coverpoint in_st  { bins st[] = {[0:3]}; }
    cp_out     : coverpoint out_st { bins st[] = {[0:3]}; }
    cp_in_seq  : coverpoint in_st  { bins b2b = (2'b11 => 2'b11 => 2'b11);
                                     bins stall_release = (2'b10 => 2'b11); }
    cp_out_seq : coverpoint out_st { bins b2b = (2'b11 => 2'b11 => 2'b11);
                                     bins stall_release = (2'b10 => 2'b11); }
    // 참고용: 어떤 in/out 조합이 나올 수 있는지는 DUT에 달려 있음
    // (예: adder는 in.ready = !out.valid | out.ready). 그래서 weight 0
    x_io : cross cp_in, cp_out { option.weight = 0; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_imp   = new("in_imp", this);
    cg_beat  = new();
    cg_cycle = new();
  endfunction

  function void write(vr_item t);
    bit [32:0] lo_sum, hi_sum;
    d = t.data;
    s = t.side;
    lo_sum   = {1'b0, d[31:0]}  + {1'b0, s};
    hi_sum   = {1'b0, d[63:32]} + {1'b0, s};
    lo_carry = lo_sum[32];
    hi_carry = hi_sum[32];
    cg_beat.sample();
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(in_vif.moncb);
      if (in_vif.moncb.rst !== 1'b0) continue;
      in_st  = {in_vif.moncb.valid  === 1'b1, in_vif.moncb.ready  === 1'b1};
      out_st = {out_vif.moncb.valid === 1'b1, out_vif.moncb.ready === 1'b1};
      cg_cycle.sample();
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("beat=%.1f%% cycle=%.1f%%",
                               cg_beat.get_inst_coverage(), cg_cycle.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
