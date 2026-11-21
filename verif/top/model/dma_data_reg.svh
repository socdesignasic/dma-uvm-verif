// dma_data_reg : 32비트 RW 데이터 레지스터 하나 (리셋 0)
//   RDMA/WDMA 바이트 수와 주소, AXI00_PTR0, VALUE_TO_ADD 6개가 이 클래스를 같이 씀
class dma_data_reg extends uvm_reg;                 // UVM 레지스터 상속
  `uvm_object_utils(dma_data_reg)                   // factory 등록
  rand uvm_reg_field value;                         // [31:0] RW, 값

  function new(string name = "dma_data_reg");       // 생성자
    super.new(name, 32, UVM_NO_COVERAGE);           // 32비트, RAL 커버리지 없음
  endfunction                                       // 생성자 끝

  virtual function void build();                    // 필드 생성과 설정
    value = uvm_reg_field::type_id::create("value");  // 필드 객체 생성
    //               parent size lsb access volatile reset has_reset rand indiv
    value.configure(this, 32,  0,  "RW",  0,       0,    1,        1,   1);  // 32비트 전체가 필드 하나
  endfunction                                       // build 끝
endclass                                            // 클래스 끝
