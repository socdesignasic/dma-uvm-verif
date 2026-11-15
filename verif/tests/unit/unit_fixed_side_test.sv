// unit_fixed_side_test : 스트림 전체에서 side 값 고정 (DMA top이 value_to_add를 쓰는 방식)
class unit_fixed_side_test extends unit_base_test;  // 기본 테스트 상속
  `uvm_component_utils(unit_fixed_side_test)        // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items                 = 1000;                 // beat 1000개
    max_delay               = 3;                    // beat 사이 최대 3사이클 쉼
    zero_delay_pct          = 70;                   // 70%는 쉬지 않음
    fix_side                = 1;                    // side 고정
    cfg.out_cfg.ready_pct   = 80;                   // 출력 ready 80%
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
