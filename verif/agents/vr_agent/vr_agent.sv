// vr_agent : builds monitor + (master: sequencer, master driver | slave: slave driver)
class vr_agent extends uvm_agent;
  `uvm_component_utils(vr_agent)
  vr_cfg           cfg;
  vr_vif           vif;
  vr_sequencer     sqr;
  vr_master_driver mdrv;
  vr_slave_driver  sdrv;
  vr_monitor       mon;
  uvm_analysis_port #(vr_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(vr_cfg)::get(this, "", "cfg", cfg))
      cfg = vr_cfg::type_id::create("cfg");
    if (!uvm_config_db#(vr_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})
    mon = vr_monitor::type_id::create("mon", this);
    case (cfg.mode)
      VR_MASTER: begin
        sqr  = vr_sequencer::type_id::create("sqr", this);
        mdrv = vr_master_driver::type_id::create("mdrv", this);
      end
      VR_SLAVE:  sdrv = vr_slave_driver::type_id::create("sdrv", this);
      default: ;
    endcase
  endfunction

  function void connect_phase(uvm_phase phase);
    mon.vif = vif;
    ap      = mon.ap;
    if (mdrv != null) begin
      mdrv.vif = vif;
      mdrv.cfg = cfg;
      mdrv.seq_item_port.connect(sqr.seq_item_export);
    end
    if (sdrv != null) begin
      sdrv.vif = vif;
      sdrv.cfg = cfg;
    end
  endfunction
endclass
