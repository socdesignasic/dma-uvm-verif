// unit_env_cfg : 기준 모델 종류 + 입력/출력 agent 설정
class unit_env_cfg extends uvm_object;
  `uvm_object_utils(unit_env_cfg)
  model_e      model   = MODEL_PASS;
  int unsigned lane_bw = 32;      // adder lane 폭 (dma_ip_top에서는 8)
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
