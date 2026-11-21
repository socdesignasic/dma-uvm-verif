// dma_env : agent, RAL 모델, predictor, scoreboard, coverage, virtual sequencer를 만들고 연결합니다.
// 자극은 여기가 아니라 sequence(verif/top/seq/)에 있습니다. job은 vsqr에서 dma_job_vseq로 돎.
//   RAL: regmodel(dma_reg_block)의 frontdoor는 axil_agt.sqr + adapter. mirror는 auto predict 대신
//        axil_monitor -> dma_predictor -> uvm_reg_predictor 순서로 갱신 (dma_predictor가 갱신 전 값을 먼저 봄).
//        읽을 때 RAL 자체 비교는 끔 (정확성 검사는 dma_predictor 몫)
//   job: dma_predictor가 블록 start 모델이 PRE에 들어가는 에지에 shadow 레지스터로 만들어 scoreboard로 보냄.
//        리셋으로 중단하면 같은 job을 다시 보냄. m00 W/B는 scoreboard로, B는 predictor로도.
//        scoreboard가 마지막 B까지 검사를 끝낸 job은 coverage(cg_job)로
class dma_env extends uvm_env;                      // UVM env 상속
  `uvm_component_utils(dma_env)                     // factory 등록
  dma_env_cfg    cfg;                               // env 설정
  axil_agent     axil_agt;   // AXI4-Lite master -> DUT 제어 레지스터
  axi4_slave_agent mem_agt;    // DUT m00에 붙는 AXI4 slave + 메모리 모델
  dma_reg_block  regmodel;                          // 레지스터 RAL 모델
  axil_reg_adapter adapter;                         // uvm_reg <-> axil_item 변환
  uvm_reg_predictor #(axil_item) reg_predictor;     // monitor가 본 접근으로 mirror 갱신
  dma_predictor  pred;                              // DUT 동작 예측과 job 생성
  dma_scoreboard sb;                                // scoreboard
  dma_coverage   cov;                               // 기능 커버리지 수집기
  dma_vsqr       vsqr;                              // job virtual sequencer (dma_job_vseq가 여기서 돎)
  axil_vif       ctl_vif;    // sequence/test가 쓰는 클럭 + 인터럽트 신호

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // 하위 컴포넌트를 만드는 build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(dma_env_cfg)::get(this, "", "cfg", cfg))  // config_db에서 env 설정 가져오기
      cfg = dma_env_cfg::type_id::create("cfg");    // 없으면 기본 설정 생성
    uvm_config_db#(axi4_slave_cfg)::set(this, "mem_agt", "cfg", cfg.slv_cfg);  // 메모리 agent에 slave 설정 전달
    uvm_config_db#(axil_cfg)::set(this, "axil_agt", "cfg", cfg.ctl_cfg);  // AXI-Lite agent에 타이밍 노브 전달
    axil_agt = axil_agent::type_id::create("axil_agt", this);  // AXI4-Lite agent 생성
    mem_agt  = axi4_slave_agent::type_id::create("mem_agt", this);  // 메모리 slave agent 생성
    regmodel = dma_reg_block::type_id::create("regmodel");  // RAL 모델 생성
    regmodel.build();                               // 레지스터 생성, map 구성, lock
    adapter  = axil_reg_adapter::type_id::create("adapter");  // adapter 생성
    reg_predictor = uvm_reg_predictor #(axil_item)::type_id::create("reg_predictor", this);  // RAL predictor 생성
    pred     = dma_predictor::type_id::create("pred", this);  // predictor 생성
    sb       = dma_scoreboard::type_id::create("sb", this);  // scoreboard 생성
    cov      = dma_coverage::type_id::create("cov", this);  // coverage 생성
    vsqr     = dma_vsqr::type_id::create("vsqr", this);  // virtual sequencer 생성
  endfunction                                       // build_phase 끝

  function void connect_phase(uvm_phase phase);     // 연결 단계
    ctl_vif = axil_agt.vif;                         // 제어 interface 핸들 저장
    regmodel.default_map.set_sequencer(axil_agt.sqr, adapter);  // RAL frontdoor = AXI4-Lite sequencer
    regmodel.default_map.set_auto_predict(0);       // 접근 직후 mirror 갱신 끔 (monitor 관찰값으로만 갱신)
    regmodel.default_map.set_check_on_read(0);      // 읽을 때 RAL 비교 끔 (dma_predictor가 맡음)
    reg_predictor.map     = regmodel.default_map;   // predictor가 주소로 찾을 map
    reg_predictor.adapter = adapter;                // predictor가 item을 바꿀 adapter
    pred.regmodel = regmodel;                       // predictor가 읽을 RAL 모델
    pred.mem      = mem_agt.mem;                    // predictor가 start 시점 스냅샷을 뜰 메모리
    pred.vif      = ctl_vif;                        // predictor가 볼 interrupt 신호
    pred.mem_vif  = mem_agt.vif;                    // predictor가 셀 m00 R handshake (작업 중 VALUE_TO_ADD)
    axil_agt.ap.connect(pred.axil_fifo.analysis_export);  // monitor가 본 접근 -> dma_predictor (먼저)
    pred.reg_ap.connect(reg_predictor.bus_in);      // dma_predictor가 처리한 접근 -> RAL predictor (그다음)
    mem_agt.b_ap.connect(pred.b_fifo.analysis_export);    // B -> predictor (job 완료)
    pred.job_ap.connect(sb.job_fifo.analysis_export);     // predictor job (리셋으로 중단하면 같은 job을 다시) -> scoreboard
    mem_agt.w_ap.connect(sb.w_fifo.analysis_export);      // W beat -> scoreboard
    mem_agt.b_ap.connect(sb.b_fifo.analysis_export);      // B -> scoreboard
    sb.mem  = mem_agt.mem;                          // scoreboard가 메모리 모델을 읽도록 연결
    mem_agt.ar_ap.connect(sb.burst_imp);            // AR burst -> scoreboard
    mem_agt.aw_ap.connect(sb.burst_imp);            // AW burst -> scoreboard
    mem_agt.ar_ap.connect(cov.burst_imp);           // AR burst -> coverage
    mem_agt.aw_ap.connect(cov.burst_imp);           // AW burst -> coverage
    sb.done_ap.connect(cov.job_fifo.analysis_export);  // scoreboard가 검사를 끝낸 job -> coverage (cg_job)
    vsqr.axil_sqr = axil_agt.sqr;                   // virtual sequencer 핸들: AXI4-Lite sequencer
    vsqr.regmodel = regmodel;                       // RAL 모델
    vsqr.mem      = mem_agt.mem;                    // 메모리 모델 (백도어)
    vsqr.ctl_vif  = ctl_vif;                        // 클럭 + interrupt
    vsqr.cfg      = cfg;                            // env 설정
    vsqr.mem_drv  = mem_agt.drv;                    // slave driver (JOB_TIMEOUT 메시지)
  endfunction                                       // connect_phase 끝

  // 테스트 끝의 RAL mirror 값 (마지막 job에서 쓴 값과 같아야 함. 사람이 보는 정보, 검사 아님)
  function void report_phase(uvm_phase phase);      // 보고 단계
    `uvm_info("RAL_MIRROR", $sformatf("rdma bytes=%0d ptr=0x%08h | wdma bytes=%0d ptr=0x%08h | value_to_add=0x%08h gie=%0d ier=%0d",  // 요약 형식
              regmodel.rdma_transfer_byte.get_mirrored_value(), regmodel.rdma_mem_ptr.get_mirrored_value(),  // RDMA
              regmodel.wdma_transfer_byte.get_mirrored_value(), regmodel.wdma_mem_ptr.get_mirrored_value(),  // WDMA
              regmodel.value_to_add.get_mirrored_value(), regmodel.gie.get_mirrored_value(),  // 더할 값, GIE
              regmodel.ier.get_mirrored_value()), UVM_LOW)  // IER
  endfunction                                       // report_phase 끝

  task clocks(int unsigned n);                      // n 클럭 기다리는 도우미
    repeat (n) @(posedge ctl_vif.clk);              // 클럭 상승 에지 n번 대기
  endtask                                           // clocks 끝
endclass                                            // 클래스 끝
