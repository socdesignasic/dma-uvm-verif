// axi4_slv_agent : 설정 + 메모리 + driver + monitor
//   mem   : 메모리 모델. env와 공유 (테스트가 채우고 scoreboard가 읽음)
//   ar_ap / aw_ap : monitor가 보내는, 받아들인 burst
class axi4_slv_agent extends uvm_agent;             // UVM agent 상속
  `uvm_component_utils(axi4_slv_agent)              // factory 등록
  axi4_vif         vif;                             // AXI4 virtual interface 핸들
  axi4_slv_cfg     cfg;                             // slave 동작 설정 (ready 확률, 지연 등)
  axi4_mem         mem;                             // 공유 메모리 모델
  axi4_slv_driver  drv;                             // slave driver (응답 생성)
  axi4_slv_monitor mon;                             // monitor (burst 수집 및 검사)
  uvm_analysis_port #(axi4_burst) ar_ap, aw_ap;     // AR / AW burst를 내보내는 analysis port

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(axi4_vif)::get(this, "", "vif", vif))  // config_db에서 virtual interface 가져오기
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})  // 없으면 바로 중단 (치명적 오류)
    if (!uvm_config_db#(axi4_slv_cfg)::get(this, "", "cfg", cfg))  // config_db에서 설정 가져오기
      cfg = axi4_slv_cfg::type_id::create("cfg");   // 없으면 기본값 설정을 새로 만듦
    mem = axi4_mem::type_id::create("mem");         // 메모리 모델 생성
    drv = axi4_slv_driver::type_id::create("drv", this);  // driver 생성
    mon = axi4_slv_monitor::type_id::create("mon", this);  // monitor 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 컴포넌트를 서로 연결하는 단계
    drv.vif = vif;  drv.cfg = cfg;  drv.mem = mem;  // driver에 interface, 설정, 메모리 전달
    mon.vif = vif;  mon.cfg = cfg;                  // monitor에 interface, 설정 전달
    ar_ap = mon.ar_ap;                              // agent의 AR port를 monitor의 것으로 연결
    aw_ap = mon.aw_ap;                              // agent의 AW port를 monitor의 것으로 연결
  endfunction                                       // connect_phase 끝
endclass                                            // 클래스 끝
