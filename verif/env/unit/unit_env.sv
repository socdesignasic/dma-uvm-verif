// unit_env : 입력/출력 vr agent + scoreboard + coverage
class unit_env extends uvm_env;
  `uvm_component_utils(unit_env)
  unit_env_cfg    cfg;
  vr_agent        in_agt, out_agt;
  unit_scoreboard sb;
  unit_coverage   cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(unit_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NO_CFG", "unit_env_cfg not set")
    uvm_config_db#(vr_cfg)::set(this, "in_agt",  "cfg", cfg.in_cfg);
    uvm_config_db#(vr_cfg)::set(this, "out_agt", "cfg", cfg.out_cfg);
    in_agt  = vr_agent::type_id::create("in_agt",  this);
    out_agt = vr_agent::type_id::create("out_agt", this);
    sb      = unit_scoreboard::type_id::create("sb", this);
    cov     = unit_coverage::type_id::create("cov", this);
    sb.cfg  = cfg;
  endfunction

  function void connect_phase(uvm_phase phase);
    in_agt.ap.connect(sb.in_imp);
    out_agt.ap.connect(sb.out_imp);
    in_agt.ap.connect(cov.in_imp);
    cov.in_vif  = in_agt.vif;
    cov.out_vif = out_agt.vif;
  endfunction
endclass
