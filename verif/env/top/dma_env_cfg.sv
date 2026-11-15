// dma_env_cfg : env 설정값 (메모리 slave backpressure, 타임아웃용 클럭 주기)
class dma_env_cfg extends uvm_object;               // UVM object 상속
  `uvm_object_utils(dma_env_cfg)                    // factory 등록
  axi4_slv_cfg slv_cfg;                             // 메모리 slave 설정 (backpressure, 지연)
  int unsigned clk_period_ns = 10;                  // 클럭 주기 (ns), 타임아웃 계산에 사용

  function new(string name = "dma_env_cfg");        // 생성자
    super.new(name);                                // 부모 생성자 호출
    slv_cfg = axi4_slv_cfg::type_id::create("slv_cfg");  // slave 설정 객체 생성
  endfunction                                       // 생성자 끝
endclass                                            // 클래스 끝
