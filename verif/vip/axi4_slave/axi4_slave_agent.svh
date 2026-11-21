// axi4_slave_agent : 설정 + 메모리 + driver + monitor
//   mem   : 메모리 모델. env와 공유 (테스트가 채우고 scoreboard가 읽음)
//   ar_ap / aw_ap : monitor가 보내는, 받아들인 burst
//   w_ap  / b_ap  : monitor가 보내는 W beat, B 응답 (axi4_wb_item)
class axi4_slave_agent extends uvm_agent;             // UVM agent 상속
  `uvm_component_utils(axi4_slave_agent)              // factory 등록
  axi4_vif         vif;                             // AXI4 virtual interface 핸들
  axi4_slave_cfg     cfg;                             // slave 동작 설정 (ready 확률, 지연 등)
  axi4_mem         mem;                             // 공유 메모리 모델
  axi4_slave_driver  drv;                             // slave driver (응답 생성)
  axi4_slave_monitor mon;                             // monitor (burst 수집 및 검사)
  uvm_analysis_port #(axi4_item) ar_ap, aw_ap;     // AR / AW burst를 내보내는 analysis port
  uvm_analysis_port #(axi4_wb_item) w_ap, b_ap;     // W beat / B 응답을 내보내는 analysis port

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(axi4_vif)::get(this, "", "vif", vif))  // config_db에서 virtual interface 가져오기
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})  // 없으면 바로 중단 (치명적 오류)
    if (!uvm_config_db#(axi4_slave_cfg)::get(this, "", "cfg", cfg))  // config_db에서 설정 가져오기
      cfg = axi4_slave_cfg::type_id::create("cfg");   // 없으면 기본값 설정을 새로 만듦
    mem = axi4_mem::type_id::create("mem");         // 메모리 모델 생성
    drv = axi4_slave_driver::type_id::create("drv", this);  // driver 생성
    mon = axi4_slave_monitor::type_id::create("mon", this);  // monitor 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 컴포넌트를 서로 연결하는 단계
    drv.vif = vif;  drv.cfg = cfg;  drv.mem = mem;  // driver에 interface, 설정, 메모리 전달
    mon.vif = vif;  mon.cfg = cfg;                  // monitor에 interface, 설정 전달
    ar_ap = mon.ar_ap;                              // agent의 AR port를 monitor의 것으로 연결
    aw_ap = mon.aw_ap;                              // agent의 AW port를 monitor의 것으로 연결
    w_ap  = mon.w_ap;                               // agent의 W port를 monitor의 것으로 연결
    b_ap  = mon.b_ap;                               // agent의 B port를 monitor의 것으로 연결
  endfunction                                       // connect_phase 끝

  // monitor가 본 수와 driver가 처리한 수를 한 줄에 (비교는 사람/스크립트가 함, 검사 아님)
  function void report_phase(uvm_phase phase);      // 보고 단계
    `uvm_info("AXI_COUNT", $sformatf("W beats monitor=%0d driver=%0d | R beats driver=%0d | B=%0d AW=%0d (monitor)",  // 요약 형식
                                     mon.n_w, drv.n_wr_beats, drv.n_rd_beats, mon.n_b, mon.n_aw), UVM_LOW)  // W/R beat 수, B와 AW 수
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
