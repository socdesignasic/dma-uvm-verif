// axil_agent : sequencer + driver (능동 master)
class axil_agent extends uvm_agent;                 // UVM agent 상속
  `uvm_component_utils(axil_agent)                  // factory 등록
  axil_vif       vif;                               // AXI4-Lite virtual interface 핸들
  axil_sequencer sqr;                               // sequencer
  axil_driver    drv;                               // driver

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(axil_vif)::get(this, "", "vif", vif))  // config_db에서 virtual interface 가져오기
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})  // 없으면 바로 중단
    sqr = axil_sequencer::type_id::create("sqr", this);  // sequencer 생성
    drv = axil_driver::type_id::create("drv", this);  // driver 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계
    drv.vif = vif;                                  // driver에 interface 전달
    drv.seq_item_port.connect(sqr.seq_item_export);  // driver와 sequencer 연결
  endfunction                                       // connect_phase 끝
endclass                                            // 클래스 끝
