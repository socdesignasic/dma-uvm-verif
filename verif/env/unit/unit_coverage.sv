// unit_coverage : beat values (corners, carries) + per-cycle handshake states
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
    // carry computed in write(): XSim mis-evaluates width-cast coverpoint expressions
    cp_lo_carry : coverpoint lo_carry { bins no = {0}; bins yes = {1}; }
    cp_hi_carry : coverpoint hi_carry { bins no = {0}; bins yes = {1}; }
  endgroup

  // per-cycle handshake state: 00 idle, 01 ready-only, 10 stalled, 11 transfer
  covergroup cg_cycle;
    option.per_instance = 1;
    cp_in      : coverpoint in_st  { bins st[] = {[0:3]}; }
    cp_out     : coverpoint out_st { bins st[] = {[0:3]}; }
    cp_in_seq  : coverpoint in_st  { bins b2b = (2'b11 => 2'b11 => 2'b11);
                                     bins stall_release = (2'b10 => 2'b11); }
    cp_out_seq : coverpoint out_st { bins b2b = (2'b11 => 2'b11 => 2'b11);
                                     bins stall_release = (2'b10 => 2'b11); }
    // informational only: which in/out combinations are reachable depends on
    // the DUT (e.g. adder: in.ready = !out.valid | out.ready), so weight 0
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
