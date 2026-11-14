// unit_env_cfg : reference-model kind + in/out agent configs
class unit_env_cfg extends uvm_object;
  `uvm_object_utils(unit_env_cfg)
  model_e      model   = MODEL_PASS;
  int unsigned lane_bw = 32;      // adder lane width (8 in dma_ip_top)
  vr_cfg  in_cfg;
  vr_cfg  out_cfg;

  function new(string name = "unit_env_cfg");
    super.new(name);
    in_cfg       = vr_cfg::type_id::create("in_cfg");
    in_cfg.mode  = VR_MASTER;
    out_cfg      = vr_cfg::type_id::create("out_cfg");
    out_cfg.mode = VR_SLAVE;
  endfunction
endclass
