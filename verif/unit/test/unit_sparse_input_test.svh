// unit_sparse_input_test : 입력은 띄엄띄엄, 출력은 항상 ready: 대부분 비어 있는 상태로 동작
class unit_sparse_input_test extends unit_base_test;     // 기본 테스트 상속
  `uvm_component_utils(unit_sparse_input_test)           // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_items        = 300;                           // beat 300개
    max_delay      = 20;                            // beat 사이 최대 20사이클 쉼
    zero_delay_pct = 10;                            // 10%만 쉬지 않음
  endfunction                                       // configure 끝
endclass                                            // 클래스 끝
