// dma_env : agent, scoreboard, coverage를 만들고 연결합니다.
// 자극은 여기가 아니라 sequence(verif/sequences/top/)에 있습니다.
class dma_env extends uvm_env;                      // UVM env 상속
  `uvm_component_utils(dma_env)                     // factory 등록
  dma_env_cfg    cfg;                               // env 설정
  axil_agent     axil_agt;   // AXI4-Lite master -> DUT 제어 레지스터
  axi4_slv_agent mem_agt;    // DUT m00에 붙는 AXI4 slave + 메모리 모델
  dma_scoreboard sb;                                // scoreboard
  dma_coverage   cov;                               // 기능 커버리지 수집기
  axil_vif       ctl_vif;    // sequence/test가 쓰는 클럭 + 인터럽트 신호

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(dma_env_cfg)::get(this, "", "cfg", cfg))  // config_db에서 env 설정 가져오기
      cfg = dma_env_cfg::type_id::create("cfg");    // 없으면 기본 설정 생성
    uvm_config_db#(axi4_slv_cfg)::set(this, "mem_agt", "cfg", cfg.slv_cfg);  // 메모리 agent에 slave 설정 전달
    axil_agt = axil_agent::type_id::create("axil_agt", this);  // AXI4-Lite agent 생성
    mem_agt  = axi4_slv_agent::type_id::create("mem_agt", this);  // 메모리 slave agent 생성
    sb       = dma_scoreboard::type_id::create("sb", this);  // scoreboard 생성
    cov      = dma_coverage::type_id::create("cov", this);  // coverage 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계
    ctl_vif = axil_agt.vif;                         // 제어 interface 핸들 저장
    sb.mem  = mem_agt.mem;                          // scoreboard가 메모리 모델을 읽도록 연결
    mem_agt.ar_ap.connect(sb.burst_imp);            // AR burst -> scoreboard
    mem_agt.aw_ap.connect(sb.burst_imp);            // AW burst -> scoreboard
    mem_agt.ar_ap.connect(cov.burst_imp);           // AR burst -> coverage
    mem_agt.aw_ap.connect(cov.burst_imp);           // AW burst -> coverage
  endfunction                                       // connect_phase 끝

  task clocks(int unsigned n);                      // n 클럭 기다리는 도우미
    repeat (n) @(posedge ctl_vif.clk);              // 클럭 상승 에지 n번 대기
  endtask                                           // clocks 끝
endclass                                            // 클래스 끝
