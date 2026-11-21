// dma_env_cfg : env 설정값 (메모리 slave backpressure, AXI-Lite master 타이밍, 타임아웃용 클럭 주기)
class dma_env_cfg extends uvm_object;               // UVM object 상속
  `uvm_object_utils(dma_env_cfg)                    // factory 등록
  axi4_slave_cfg slv_cfg;                             // 메모리 slave 설정 (backpressure, 지연)
  axil_cfg       ctl_cfg;                           // 제어 AXI-Lite master(axil_agt) 타이밍 노브 (기본 0 = AW/W 같은 사이클, READY 미리)
  int unsigned clk_period_ns = 10;                  // 클럭 주기 (ns), 타임아웃 계산에 사용

  function new(string name = "dma_env_cfg");        // 생성자
    super.new(name);                                // 부모 생성자 호출
    slv_cfg = axi4_slave_cfg::type_id::create("slv_cfg");  // slave 설정 객체 생성
    ctl_cfg = axil_cfg::type_id::create("ctl_cfg"); // AXI-Lite master 타이밍 노브 생성
  endfunction                                       // 생성자 끝
endclass                                            // 클래스 끝
