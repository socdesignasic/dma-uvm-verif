// dma_gie_reg : GIE (0x04) 레지스터 모델
//   gie[0] RW (리셋 0), 정의되지 않은 [31:1]은 RO 필드(리셋 0)
class dma_gie_reg extends uvm_reg;                  // UVM 레지스터 상속
  `uvm_object_utils(dma_gie_reg)                    // factory 등록
  rand uvm_reg_field gie;                           // [0]    RW, 전역 인터럽트 enable
  uvm_reg_field      rsvd_31_1;                     // [31:1] RO, 정의 안 됨 (0)

  function new(string name = "dma_gie_reg");        // 생성자
    super.new(name, 32, UVM_NO_COVERAGE);           // 32비트, RAL 커버리지 없음
  endfunction                                       // 생성자 끝

  virtual function void build();                    // 필드 생성과 설정
    gie       = uvm_reg_field::type_id::create("gie");        // 필드 객체 생성
    rsvd_31_1 = uvm_reg_field::type_id::create("rsvd_31_1");  // 필드 객체 생성
    //                   parent size lsb access volatile reset has_reset rand indiv
    gie      .configure(this,  1,  0,  "RW",  0,       0,    1,        1,   0);  // enable 비트
    rsvd_31_1.configure(this, 31,  1,  "RO",  0,       0,    1,        0,   0);  // 예약 [31:1]
  endfunction                                       // build 끝
endclass                                            // 클래스 끝
