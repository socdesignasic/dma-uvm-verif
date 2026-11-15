// axi4_slv_cfg : slave의 채널별 backpressure와 지연 설정값
class axi4_slv_cfg extends uvm_object;
  `uvm_object_utils(axi4_slv_cfg)
  int unsigned ar_ready_pct  = 100;  // 사이클마다 ARREADY=1일 확률(%)
  int unsigned aw_ready_pct  = 100;
  int unsigned aw_fixed_wait = 0;    // >0이면 AWVALID 후 이 사이클 수만큼 AWREADY를 0으로 유지
  int unsigned w_ready_pct   = 100;
  int unsigned r_gap_pct     = 0;    // R beat 앞에 빈 사이클을 넣을 확률(%)
  int unsigned max_r_latency = 0;    // AR 수락 -> 첫 R beat까지의 사이클 (0..max 균등 분포)
  int unsigned max_b_latency = 0;    // 마지막 W -> BVALID까지의 사이클
  int unsigned max_burst_len = 16;   // DUT 사양: 최대 16 beat

  function new(string name = "axi4_slv_cfg");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("ready%% ar=%0d aw=%0d w=%0d | r_gap=%0d%% r_lat<=%0d b_lat<=%0d",
                     ar_ready_pct, aw_ready_pct, w_ready_pct, r_gap_pct,
                     max_r_latency, max_b_latency);
  endfunction
endclass
