// unit_env_cfg : 기준 모델 종류 + 입력/출력 agent 설정
class unit_env_cfg extends uvm_object;              // UVM object 상속
  `uvm_object_utils(unit_env_cfg)                   // factory 등록
  model_e      model   = MODEL_PASS;                // 기준 모델 (기본: 그대로 통과)
  int unsigned lane_bw = 32;      // adder lane 폭 (dma_ip_top에서는 8)
  vr_cfg  in_cfg;                                   // 입력 agent 설정
  vr_cfg  out_cfg;                                  // 출력 agent 설정

  function new(string name = "unit_env_cfg");       // 생성자
    super.new(name);                                // 부모 생성자 호출
    in_cfg       = vr_cfg::type_id::create("in_cfg");  // 입력 설정 생성
    in_cfg.mode  = VR_MASTER;                       // 입력은 master (TB가 구동)
    out_cfg      = vr_cfg::type_id::create("out_cfg");  // 출력 설정 생성
    out_cfg.mode = VR_SLAVE;                        // 출력은 slave (TB가 ready 구동)
  endfunction                                       // 생성자 끝
endclass                                            // 클래스 끝
