// unit_backpressure_test : 강한 backpressure: FIFO를 가득 채우고 skid 상태를 동작시킴
class unit_backpressure_test extends unit_base_test;  // 기본 테스트 상속
  `uvm_component_utils(unit_backpressure_test)      // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items                 = 1000;                 // beat 1000개
    cfg.out_cfg.ready_pct   = 25;                   // 출력 ready 25%
    cfg.out_cfg.stall_pct   = 10;                   // 긴 stall 시작 확률 10%
    cfg.out_cfg.max_stall   = 80;                   // 긴 stall 최대 80사이클
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
