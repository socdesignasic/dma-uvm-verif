// dma_vsqr : DMA job 자극용 virtual sequencer (item을 직접 받지 않고 핸들만 가짐). env가 connect_phase에서 채움
//   dma_job_vseq가 p_sequencer로 씀
//   axil_sqr : AXI4-Lite sequencer. regmodel.default_map의 frontdoor가 bus item을 여기로 보냄
//   regmodel : 레지스터 접근 (regmodel.<reg>.write/read, frontdoor). mirror는 monitor 경로로만 갱신 (auto predict 끔)
//   mem      : 메모리 모델 백도어 (src 데이터, guard, pre-poison을 직접 씀)
//   ctl_vif  : 클럭과 interrupt 핀
//   cfg      : 완료 대기 시간 한도 계산용 (클럭 주기, slave 지연 상한)
//   mem_drv  : JOB_TIMEOUT 메시지에 넣을 진행 상황 (slave driver가 처리한 R/W beat 수)
//   rst_vif  : 테스트 중간 리셋 (dma_reset_vseq가 씀). env가 아니라 여기 build_phase에서 config_db로 받음 (tb_dma가 넣음)
class dma_vsqr extends uvm_sequencer #(uvm_sequence_item);  // virtual sequencer (item 없음)
  `uvm_component_utils(dma_vsqr)                    // factory 등록
  axil_sequencer    axil_sqr;                       // AXI4-Lite sequencer (RAL frontdoor 대상)
  dma_reg_block     regmodel;                       // 레지스터 RAL 모델
  axi4_mem          mem;                            // 메모리 모델 (백도어)
  axil_vif          ctl_vif;                        // 클럭 + interrupt 신호
  dma_env_cfg       cfg;                            // env 설정
  axi4_slave_driver mem_drv;                        // slave driver (JOB_TIMEOUT 메시지의 beat 수)
  virtual dma_reset_if rst_vif;                     // 리셋 interface (전원 리셋과 같은 신호)

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function void build_phase(uvm_phase phase);       // build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    if (!uvm_config_db#(virtual dma_reset_if)::get(this, "", "rst_vif", rst_vif))  // config_db에서 리셋 interface 가져오기
      `uvm_fatal("NO_VIF", {"virtual interface must be set for: ", get_full_name(), ".rst_vif"})  // 없으면 바로 중단
  endfunction                                       // build_phase 끝
endclass                                            // 클래스 끝
