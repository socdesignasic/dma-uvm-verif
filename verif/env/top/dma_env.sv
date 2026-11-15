// dma_env : agent, scoreboard, coverage를 만들고 연결합니다.
// 자극은 여기가 아니라 sequence(verif/sequences/top/)에 있습니다.
class dma_env extends uvm_env;
  `uvm_component_utils(dma_env)
  dma_env_cfg    cfg;
  axil_agent     axil_agt;   // AXI4-Lite master -> DUT 제어 레지스터
  axi4_slv_agent mem_agt;    // DUT m00에 붙는 AXI4 slave + 메모리 모델
  dma_scoreboard sb;
  dma_coverage   cov;
  axil_vif       ctl_vif;    // sequence/test가 쓰는 클럭 + 인터럽트 신호

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(dma_env_cfg)::get(this, "", "cfg", cfg))
      cfg = dma_env_cfg::type_id::create("cfg");
    uvm_config_db#(axi4_slv_cfg)::set(this, "mem_agt", "cfg", cfg.slv_cfg);
    axil_agt = axil_agent::type_id::create("axil_agt", this);
    mem_agt  = axi4_slv_agent::type_id::create("mem_agt", this);
    sb       = dma_scoreboard::type_id::create("sb", this);
    cov      = dma_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    ctl_vif = axil_agt.vif;
    sb.mem  = mem_agt.mem;
    mem_agt.ar_ap.connect(sb.burst_imp);
    mem_agt.aw_ap.connect(sb.burst_imp);
    mem_agt.ar_ap.connect(cov.burst_imp);
    mem_agt.aw_ap.connect(cov.burst_imp);
  endfunction

  task clocks(int unsigned n);
    repeat (n) @(posedge ctl_vif.clk);
  endtask
endclass
