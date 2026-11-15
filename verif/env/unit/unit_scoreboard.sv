// unit_scoreboard : 출력 beat를 모델(입력 beat)과 순서대로 비교
`uvm_analysis_imp_decl(_in)
`uvm_analysis_imp_decl(_out)

class unit_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(unit_scoreboard)
  uvm_analysis_imp_in  #(vr_item, unit_scoreboard) in_imp;
  uvm_analysis_imp_out #(vr_item, unit_scoreboard) out_imp;
  unit_env_cfg cfg;

  bit [63:0]   exp_q[$];
  int unsigned n_in, n_out, n_match, n_mismatch;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_imp  = new("in_imp", this);
    out_imp = new("out_imp", this);
  endfunction

  function bit [63:0] model(vr_item t);
    bit [63:0] r;
    bit [63:0] mask = (64'h1 << cfg.lane_bw) - 1;
    if (cfg.model != MODEL_ADD) return t.data;
    for (int l = 0; l < 64 / cfg.lane_bw; l++)
      r |= (((t.data >> (l * cfg.lane_bw)) + t.side) & mask) << (l * cfg.lane_bw);
    return r;
  endfunction

  function void write_in(vr_item t);
    exp_q.push_back(model(t));
    n_in++;
  endfunction

  function void write_out(vr_item t);
    bit [63:0] exp;
    n_out++;
    if (exp_q.size() == 0) begin
      `uvm_error("SB_UNEXPECTED", $sformatf("beat #%0d: output with no pending input: %s",
                                            n_out, t.convert2string()))
      return;
    end
    exp = exp_q.pop_front();
    if (t.data !== exp) begin
      n_mismatch++;
      `uvm_error("SB_MISMATCH", $sformatf("beat #%0d: exp=0x%016h act=0x%016h",
                                          n_out, exp, t.data))
    end else
      n_match++;
  endfunction

  function void check_phase(uvm_phase phase);
    if (n_in == 0)
      `uvm_error("SB_NO_TRAFFIC", "no input beats observed")
    if (exp_q.size() != 0)
      `uvm_error("SB_LEFTOVER", $sformatf("%0d input beats never came out (first exp=0x%016h)",
                                          exp_q.size(), exp_q[0]))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB_SUMMARY", $sformatf("in=%0d out=%0d match=%0d mismatch=%0d pending=%0d",
                                      n_in, n_out, n_match, n_mismatch, exp_q.size()), UVM_LOW)
  endfunction
endclass
