// unit_single_beat_test : 리셋이 충분히 지난 뒤 beat 1개만 보내고 끝남 (1건 비교, 끝의 남은/예상 밖 beat 검사)
class unit_single_beat_test extends unit_base_test;  // 기본 테스트 상속
  `uvm_component_utils(unit_single_beat_test)       // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items                    = 1;                 // beat 1개
    cfg.in_cfg.post_reset_idle = 20;                // 리셋 후 20사이클 쉬고 시작 (BUG-001 구간을 피함)
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
