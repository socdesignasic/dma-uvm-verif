// dma_ap_ctrl_reg : AP_CTRL (0x00) 레지스터 모델
//   start[0] RW, done[1] RC, idle[2] RO(리셋 1), ready[3] RC, auto_restart[7] RW, interrupt[9] RO
//   정의되지 않은 비트([6:4], [8], [31:10])도 RO 필드(리셋 0)로 두어 32비트 전체를 덮음
//   start가 handshake에서 지워지는 것(COH), done/idle/ready/interrupt의 변화는 dma_predictor가 예측함
//   리셋 값이 정해진 필드는 모두 volatile=0 (uvm_reg_hw_reset_seq가 0x4까지 비교하도록)
class dma_ap_ctrl_reg extends uvm_reg;              // UVM 레지스터 상속
  `uvm_object_utils(dma_ap_ctrl_reg)                // factory 등록
  rand uvm_reg_field ap_start;                      // [0]     RW, 시작
  uvm_reg_field      ap_done;                       // [1]     RC, 완료 (읽으면 지워짐)
  uvm_reg_field      ap_idle;                       // [2]     RO, idle (리셋 1)
  uvm_reg_field      ap_ready;                      // [3]     RC, ready (읽으면 지워짐)
  uvm_reg_field      rsvd_6_4;                      // [6:4]   RO, 정의 안 됨 (0)
  rand uvm_reg_field auto_restart;                  // [7]     RW, 자동 재시작
  uvm_reg_field      rsvd_8;                        // [8]     RO, 정의 안 됨 (0)
  uvm_reg_field      interrupt;                     // [9]     RO, 인터럽트 출력 값
  uvm_reg_field      rsvd_31_10;                    // [31:10] RO, 정의 안 됨 (0)

  function new(string name = "dma_ap_ctrl_reg");    // 생성자
    super.new(name, 32, UVM_NO_COVERAGE);           // 32비트, RAL 커버리지 없음
  endfunction                                       // 생성자 끝

  virtual function void build();                    // 필드 생성과 설정
    ap_start     = uvm_reg_field::type_id::create("ap_start");      // 필드 객체 생성
    ap_done      = uvm_reg_field::type_id::create("ap_done");       // 필드 객체 생성
    ap_idle      = uvm_reg_field::type_id::create("ap_idle");       // 필드 객체 생성
    ap_ready     = uvm_reg_field::type_id::create("ap_ready");      // 필드 객체 생성
    rsvd_6_4     = uvm_reg_field::type_id::create("rsvd_6_4");      // 필드 객체 생성
    auto_restart = uvm_reg_field::type_id::create("auto_restart");  // 필드 객체 생성
    rsvd_8       = uvm_reg_field::type_id::create("rsvd_8");        // 필드 객체 생성
    interrupt    = uvm_reg_field::type_id::create("interrupt");     // 필드 객체 생성
    rsvd_31_10   = uvm_reg_field::type_id::create("rsvd_31_10");    // 필드 객체 생성
    //                      parent size lsb              access volatile reset has_reset rand indiv
    ap_start    .configure(this,  1, AP_START,          "RW",  0,       0,    1,        1,   0);  // 시작 비트
    ap_done     .configure(this,  1, AP_DONE,           "RC",  0,       0,    1,        0,   0);  // 완료 비트
    ap_idle     .configure(this,  1, AP_IDLE,           "RO",  0,       1,    1,        0,   0);  // idle 비트 (리셋 1)
    ap_ready    .configure(this,  1, AP_READY,          "RC",  0,       0,    1,        0,   0);  // ready 비트
    rsvd_6_4    .configure(this,  3, 4,                 "RO",  0,       0,    1,        0,   0);  // 예약 [6:4]
    auto_restart.configure(this,  1, AP_AUTO_RESTART,   "RW",  0,       0,    1,        1,   0);  // 자동 재시작 비트
    rsvd_8      .configure(this,  1, 8,                 "RO",  0,       0,    1,        0,   0);  // 예약 [8]
    interrupt   .configure(this,  1, AP_INTERRUPT,      "RO",  0,       0,    1,        0,   0);  // 인터럽트 비트
    rsvd_31_10  .configure(this, 22, AP_INTERRUPT + 1,  "RO",  0,       0,    1,        0,   0);  // 예약 [31:10]
  endfunction                                       // build 끝
endclass                                            // 클래스 끝
