// dma_ier_reg : IER (0x08) 레지스터 모델
//   ier[1:0] RW (0: ap_done, 1: ap_ready, 리셋 0), 정의되지 않은 [31:2]는 RO 필드(리셋 0)
class dma_ier_reg extends uvm_reg;                  // UVM 레지스터 상속
  `uvm_object_utils(dma_ier_reg)                    // factory 등록
  rand uvm_reg_field ier;                           // [1:0]  RW, 인터럽트 enable
  uvm_reg_field      rsvd_31_2;                     // [31:2] RO, 정의 안 됨 (0)

  function new(string name = "dma_ier_reg");        // 생성자
    super.new(name, 32, UVM_NO_COVERAGE);           // 32비트, RAL 커버리지 없음
  endfunction                                       // 생성자 끝

  virtual function void build();                    // 필드 생성과 설정
    ier       = uvm_reg_field::type_id::create("ier");        // 필드 객체 생성
    rsvd_31_2 = uvm_reg_field::type_id::create("rsvd_31_2");  // 필드 객체 생성
    //                   parent size lsb access volatile reset has_reset rand indiv
    ier      .configure(this,  2,  0,  "RW",  0,       0,    1,        1,   0);  // enable 비트 2개
    rsvd_31_2.configure(this, 30,  2,  "RO",  0,       0,    1,        0,   0);  // 예약 [31:2]
  endfunction                                       // build 끝
endclass                                            // 클래스 끝
