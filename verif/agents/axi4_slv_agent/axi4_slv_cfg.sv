// axi4_slv_cfg : per-channel backpressure and latency knobs of the slave
class axi4_slv_cfg extends uvm_object;
  `uvm_object_utils(axi4_slv_cfg)
  int unsigned ar_ready_pct  = 100;  // P(ARREADY=1) per cycle
  int unsigned aw_ready_pct  = 100;
  int unsigned aw_fixed_wait = 0;    // >0: hold AWREADY low this many cycles after AWVALID
  int unsigned w_ready_pct   = 100;
  int unsigned r_gap_pct     = 0;    // P(idle cycle before an R beat)
  int unsigned max_r_latency = 0;    // cycles AR accept -> first R beat (uniform 0..max)
  int unsigned max_b_latency = 0;    // cycles last W -> BVALID
  int unsigned max_burst_len = 16;   // DUT spec: up to 16 beats

  function new(string name = "axi4_slv_cfg");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("ready%% ar=%0d aw=%0d w=%0d | r_gap=%0d%% r_lat<=%0d b_lat<=%0d",
                     ar_ready_pct, aw_ready_pct, w_ready_pct, r_gap_pct,
                     max_r_latency, max_b_latency);
  endfunction
endclass
