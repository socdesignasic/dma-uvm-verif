// unit_rand_test : 입력은 랜덤 간격, 출력은 랜덤 backpressure, beat마다 side도 랜덤
class unit_rand_test extends unit_base_test;        // 기본 테스트 상속
  `uvm_component_utils(unit_rand_test)              // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items                 = 2000;                 // beat 2000개
    max_delay               = 5;                    // beat 사이 최대 5사이클 쉼
    zero_delay_pct          = 60;                   // 60%는 쉬지 않음
    cfg.out_cfg.ready_pct   = 70;                   // 출력 ready 70%
    cfg.out_cfg.stall_pct   = 3;                    // 긴 stall 시작 확률 3%
    cfg.out_cfg.max_stall   = 20;                   // 긴 stall 최대 20사이클
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
