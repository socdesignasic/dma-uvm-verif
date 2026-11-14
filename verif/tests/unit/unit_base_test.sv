// unit_base_test : common flow (start vr_stream_seq, drain, timeout); tests override configure()
class unit_base_test extends uvm_test;
  `uvm_component_utils(unit_base_test)
  unit_env     env;
  unit_env_cfg cfg;
  string       kind;

  // stimulus knobs (set in configure())
  int unsigned n_items        = 200;
  int unsigned max_delay      = 0;
  int unsigned zero_delay_pct = 100;
  bit          fix_side       = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // override in derived tests: stimulus knobs + cfg.out_cfg backpressure
  virtual function void configure();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = unit_env_cfg::type_id::create("cfg");
    if (!uvm_config_db#(string)::get(this, "", "dut_kind", kind))
      `uvm_fatal("NO_KIND", "TB top must set dut_kind")
    cfg.model = (kind == "adder") ? MODEL_ADD : MODEL_PASS;
    void'(uvm_config_db#(int unsigned)::get(this, "", "lane_bw", cfg.lane_bw));
    // Regular tests start a few cycles after reset; the first-cycle-after-reset
    // corner is covered separately by unit_post_reset_test (see BUG-001).
    cfg.in_cfg.post_reset_idle = 3;
    configure();
    if ($value$plusargs("N_ITEMS=%d", n_items)) `uvm_info("TEST", "N_ITEMS overridden by plusarg", UVM_LOW)
    uvm_config_db#(unit_env_cfg)::set(this, "env", "cfg", cfg);
    env = unit_env::type_id::create("env", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    vr_stream_seq seq;
    longint unsigned budget_ns;
    phase.raise_objection(this);

    seq                = vr_stream_seq::type_id::create("seq");
    seq.n_items        = n_items;
    seq.max_delay      = max_delay;
    seq.zero_delay_pct = zero_delay_pct;
    seq.fix_side       = fix_side;
    seq.side_val       = $urandom;
    `uvm_info("TEST", $sformatf(
      "dut=%s items=%0d max_delay=%0d zero_delay=%0d%% | out ready=%0d%% stall=%0d%% max_stall=%0d | fix_side=%0d",
      (kind == "adder") ? $sformatf("adder/%0db", cfg.lane_bw) : kind, n_items, max_delay, zero_delay_pct, cfg.out_cfg.ready_pct,
      cfg.out_cfg.stall_pct, cfg.out_cfg.max_stall, fix_side), UVM_LOW)

    seq.start(env.in_agt.sqr);

    // drain: wait for every beat to come out, bounded by a generous budget
    budget_ns = 2000 + 10 * longint'(n_items) * (max_delay + 2 + cfg.out_cfg.max_stall) * 4;
    fork
      while (env.sb.n_out < n_items) #10ns;
      begin
        #(budget_ns * 1ns);
        `uvm_error("TIMEOUT", $sformatf("drain timeout: %0d/%0d beats out after %0d ns",
                                        env.sb.n_out, n_items, budget_ns))
      end
    join_any
    disable fork;
    #200ns;   // let any spurious extra beat show up in the scoreboard
    phase.drop_objection(this);
  endtask
endclass
