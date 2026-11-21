// unit_smoke_test : 양쪽 모두 최대 속도
class unit_smoke_test extends unit_base_test;       // 기본 테스트 상속
  `uvm_component_utils(unit_smoke_test)             // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items = 50;                                   // beat 50개 (나머지는 기본값: 쉼 없음, ready 100%)
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
