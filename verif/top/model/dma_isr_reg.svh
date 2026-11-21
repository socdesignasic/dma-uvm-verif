// dma_isr_reg : ISR (0x0C) 레지스터 모델
//   isr[1:0] RC (읽으면 지워짐, 쓰기는 무시, 리셋 0), 정의되지 않은 [31:2]는 RO 필드(리셋 0)
//   DUT가 1로 만드는 시점은 dma_predictor가 예측함
class dma_isr_reg extends uvm_reg;                  // UVM 레지스터 상속
  `uvm_object_utils(dma_isr_reg)                    // factory 등록
  uvm_reg_field isr;                                // [1:0]  RC, 인터럽트 상태
  uvm_reg_field rsvd_31_2;                          // [31:2] RO, 정의 안 됨 (0)

  function new(string name = "dma_isr_reg");        // 생성자
    super.new(name, 32, UVM_NO_COVERAGE);           // 32비트, RAL 커버리지 없음
  endfunction                                       // 생성자 끝

  virtual function void build();                    // 필드 생성과 설정
    isr       = uvm_reg_field::type_id::create("isr");        // 필드 객체 생성
    rsvd_31_2 = uvm_reg_field::type_id::create("rsvd_31_2");  // 필드 객체 생성
    //                   parent size lsb access volatile reset has_reset rand indiv
    isr      .configure(this,  2,  0,  "RC",  0,       0,    1,        0,   0);  // 상태 비트 2개
    rsvd_31_2.configure(this, 30,  2,  "RO",  0,       0,    1,        0,   0);  // 예약 [31:2]
  endfunction                                       // build 끝
endclass                                            // 클래스 끝
