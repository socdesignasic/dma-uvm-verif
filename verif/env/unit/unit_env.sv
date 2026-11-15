// unit_env : 입력/출력 vr agent + scoreboard + coverage
class unit_env extends uvm_env;                     // UVM env 상속
  `uvm_component_utils(unit_env)                    // factory 등록
  unit_env_cfg    cfg;                              // env 설정
  vr_agent        in_agt, out_agt;                  // 입력 agent, 출력 agent
  unit_scoreboard sb;                               // scoreboard
  unit_coverage   cov;                              // coverage

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(unit_env_cfg)::get(this, "", "cfg", cfg))  // config_db에서 env 설정 가져오기
      `uvm_fatal("NO_CFG", "unit_env_cfg not set")  // 없으면 바로 중단 (test가 반드시 설정)
    uvm_config_db#(vr_cfg)::set(this, "in_agt",  "cfg", cfg.in_cfg);  // 입력 agent 설정 전달
    uvm_config_db#(vr_cfg)::set(this, "out_agt", "cfg", cfg.out_cfg);  // 출력 agent 설정 전달
    in_agt  = vr_agent::type_id::create("in_agt",  this);  // 입력 agent 생성
    out_agt = vr_agent::type_id::create("out_agt", this);  // 출력 agent 생성
    sb      = unit_scoreboard::type_id::create("sb", this);  // scoreboard 생성
    cov     = unit_coverage::type_id::create("cov", this);  // coverage 생성
    sb.cfg  = cfg;                                  // scoreboard에 설정 전달
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계
    in_agt.ap.connect(sb.in_imp);                   // 입력 beat -> scoreboard
    out_agt.ap.connect(sb.out_imp);                 // 출력 beat -> scoreboard
    in_agt.ap.connect(cov.in_imp);                  // 입력 beat -> coverage
    cov.in_vif  = in_agt.vif;                       // coverage에 입력 interface 전달
    cov.out_vif = out_agt.vif;                      // coverage에 출력 interface 전달
  endfunction                                       // connect_phase 끝
endclass                                            // 클래스 끝
