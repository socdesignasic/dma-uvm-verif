// axil_agent : sequencer + driver (능동 master) + monitor
//   ap  : monitor가 본 AXI-Lite 접근 (쓰기는 AW+W 에지, 읽기는 R 에지)
//   cfg : driver 타이밍 노브 (config_db "cfg", 없으면 기본값 0)
class axil_agent extends uvm_agent;                 // UVM agent 상속
  `uvm_component_utils(axil_agent)                  // factory 등록
  axil_vif       vif;                               // AXI4-Lite virtual interface 핸들
  axil_cfg       cfg;                               // driver 타이밍 노브
  axil_sequencer sqr;                               // sequencer
  axil_driver    drv;                               // driver
  axil_monitor   mon;                               // monitor
  uvm_analysis_port #(axil_item) ap;                // monitor가 본 접근을 내보내는 analysis port

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(axil_vif)::get(this, "", "vif", vif))  // config_db에서 virtual interface 가져오기
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})  // 없으면 바로 중단
    if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg))  // config_db에서 타이밍 노브 가져오기
      cfg = axil_cfg::type_id::create("cfg");       // 없으면 기본값 (0)
    sqr = axil_sequencer::type_id::create("sqr", this);  // sequencer 생성
    drv = axil_driver::type_id::create("drv", this);  // driver 생성
    mon = axil_monitor::type_id::create("mon", this);  // monitor 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계
    drv.vif = vif;                                  // driver에 interface 전달
    drv.cfg = cfg;                                  // driver에 타이밍 노브 전달
    drv.seq_item_port.connect(sqr.seq_item_export);  // driver와 sequencer 연결
    mon.vif = vif;                                  // monitor에 interface 전달
    ap      = mon.ap;                               // agent port를 monitor port로 연결
  endfunction                                       // connect_phase 끝

  // driver가 처리한 수와 monitor가 본 수를 한 줄에 (비교는 사람/스크립트가 함, 검사 아님)
  function void report_phase(uvm_phase phase);      // 보고 단계
    `uvm_info("AXIL_COUNT", $sformatf("driver wr=%0d rd=%0d | monitor wr=%0d rd=%0d B=%0d",  // 요약 형식
                                      drv.n_wr, drv.n_rd, mon.n_wr, mon.n_rd, mon.n_b), UVM_LOW)  // driver 수, monitor 수
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
