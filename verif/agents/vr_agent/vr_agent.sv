// vr_agent : monitor + (master: sequencer, master driver | slave: slave driver)를 만듦
class vr_agent extends uvm_agent;                   // UVM agent 상속
  `uvm_component_utils(vr_agent)                    // factory 등록
  vr_cfg           cfg;                             // agent 설정 (모드 등)
  vr_vif           vif;                             // valid/ready virtual interface 핸들
  vr_sequencer     sqr;                             // sequencer (master 모드)
  vr_master_driver mdrv;                            // master driver (master 모드)
  vr_slave_driver  sdrv;                            // slave driver (slave 모드)
  vr_monitor       mon;                             // monitor (모든 모드)
  uvm_analysis_port #(vr_item) ap;                  // monitor가 본 beat를 내보내는 analysis port

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(vr_cfg)::get(this, "", "cfg", cfg))  // config_db에서 설정 가져오기
      cfg = vr_cfg::type_id::create("cfg");         // 없으면 기본 설정 생성
    if (!uvm_config_db#(vr_vif)::get(this, "", "vif", vif))  // config_db에서 virtual interface 가져오기
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".vif"})  // 없으면 바로 중단
    mon = vr_monitor::type_id::create("mon", this);  // monitor는 항상 생성
    case (cfg.mode)                                 // 모드에 따라 나머지 생성
      VR_MASTER: begin                              // master 모드면
        sqr  = vr_sequencer::type_id::create("sqr", this);  // sequencer 생성
        mdrv = vr_master_driver::type_id::create("mdrv", this);  // master driver 생성
      end                                           // master 끝
      VR_SLAVE:  sdrv = vr_slave_driver::type_id::create("sdrv", this);  // slave 모드면 slave driver 생성
      default: ;                                    // passive 모드면 아무것도 안 함
    endcase                                         // case 끝
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계
    mon.vif = vif;                                  // monitor에 interface 전달
    ap      = mon.ap;                               // agent port를 monitor port로 연결
    if (mdrv != null) begin                         // master driver가 있으면
      mdrv.vif = vif;                               // interface 전달
      mdrv.cfg = cfg;                               // 설정 전달
      mdrv.seq_item_port.connect(sqr.seq_item_export);  // driver와 sequencer 연결
    end                                             // if 끝
    if (sdrv != null) begin                         // slave driver가 있으면
      sdrv.vif = vif;                               // interface 전달
      sdrv.cfg = cfg;                               // 설정 전달
    end                                             // if 끝
  endfunction                                       // connect_phase 끝
endclass                                            // 클래스 끝
