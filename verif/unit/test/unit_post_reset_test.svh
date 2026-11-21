// unit_post_reset_test : 리셋이 풀리는 첫 사이클부터 valid를 켬 (BUG-001 재현)
class unit_post_reset_test extends unit_base_test;  // 기본 테스트 상속
  `uvm_component_utils(unit_post_reset_test)        // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items                    = 50;                // beat 50개
    cfg.in_cfg.post_reset_idle = 0;                 // 리셋 후 쉬지 않고 바로 시작
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
