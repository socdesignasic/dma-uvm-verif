// axi4_slv_agent : 설정 + 메모리 + driver + monitor
//   mem   : 메모리 모델. env와 공유 (테스트가 채우고 scoreboard가 읽음)
//   ar_ap / aw_ap : monitor가 보내는, 받아들인 burst
class axi4_slv_agent extends uvm_agent;
  `uvm_component_utils(axi4_slv_agent)
  axi4_vif         vif;
  axi4_slv_cfg     cfg;
  axi4_mem         mem;
  axi4_slv_driver  drv;
  axi4_slv_monitor mon;
  uvm_analysis_port #(axi4_burst) ar_ap, aw_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axi4_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})
    if (!uvm_config_db#(axi4_slv_cfg)::get(this, "", "cfg", cfg))
      cfg = axi4_slv_cfg::type_id::create("cfg");
    mem = axi4_mem::type_id::create("mem");
    drv = axi4_slv_driver::type_id::create("drv", this);
    mon = axi4_slv_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.vif = vif;  drv.cfg = cfg;  drv.mem = mem;
    mon.vif = vif;  mon.cfg = cfg;
    ar_ap = mon.ar_ap;
    aw_ap = mon.aw_ap;
  endfunction
endclass
