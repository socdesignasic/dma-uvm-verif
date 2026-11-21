// dma_reg_bitbash_vseq : RW 레지스터 8개(GIE, IER, 데이터 6개)의 32비트를 RAL 내장 bit-bash로 쓰고 읽음 (virtual sequence,
//                        env.vsqr = dma_vsqr에서 실행). 자극만 담음
//   1회차 (0 배경): uvm_reg_bit_bash_seq. 비트마다 배경의 그 비트만 뒤집어 쓰고 읽은 뒤 되돌림 (walking-1)
//         이 sequence는 시작할 때 model.reset()을 부름 -> DUT가 리셋 상태일 때만 실행 (test가 리셋 직후 한 번)
//   2회차 (1 배경): 8개에 32'hFFFF_FFFF를 쓴 뒤 레지스터마다 uvm_reg_single_bit_bash_seq (walking-0).
//         model.reset()을 부르지 않으므로 배경은 rg.get() = 쓴 값의 RW 필드 (예약 비트는 RO 필드라 0)
//   끝나면 8개를 0으로 되돌림
//   예약 비트(RO 필드)에도 1을 씀. DUT는 무시해야 함
//   제외: AP_CTRL (start를 쓰면 DMA가 시작됨), ISR (읽으면 지워짐) -> dma_reg_block::build가 넣는
//         NO_REG_BIT_BASH_TEST resource (내장 sequence가 보고 건너뜀). 2회차 목록에도 넣지 않음
//   레지스터 접근은 regmodel의 frontdoor (uvm_reg_map -> adapter -> AXI4-Lite sequencer)
//   읽기값 검사: dma_predictor가 모든 읽기를 32비트 전체로 비교 (예약 비트 = 0, RW 필드 = mirror -> REG_BITBASH).
//         내장 sequence도 자체 비교를 함 (rg.get()과 읽은 값)
class dma_reg_bitbash_vseq extends uvm_sequence #(uvm_sequence_item);  // virtual sequence (item을 직접 보내지 않음)
  `uvm_object_utils(dma_reg_bitbash_vseq)           // factory 등록
  `uvm_declare_p_sequencer(dma_vsqr)                // p_sequencer = dma_vsqr

  function new(string name = "dma_reg_bitbash_vseq");  // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    dma_reg_block               rm = p_sequencer.regmodel;  // RAL 모델 핸들
    uvm_reg                     regs[$];            // 2회차 대상 RW 레지스터 8개
    uvm_reg_bit_bash_seq        bash0;              // 1회차 (0 배경)
    uvm_reg_single_bit_bash_seq bash1;              // 2회차 (1 배경, 레지스터 하나씩)
    uvm_status_e                status;             // 접근 결과 (응답 코드는 axil_monitor가 검사)

    regs.push_back(rm.gie);                         // 0x04
    regs.push_back(rm.ier);                         // 0x08
    regs.push_back(rm.rdma_transfer_byte);          // 0x10
    regs.push_back(rm.rdma_mem_ptr);                // 0x14
    regs.push_back(rm.wdma_transfer_byte);          // 0x18
    regs.push_back(rm.wdma_mem_ptr);                // 0x1C
    regs.push_back(rm.axi00_ptr0);                  // 0x20
    regs.push_back(rm.value_to_add);                // 0x24

    // 1회차: 0 배경 (model.reset() 뒤 모든 비트가 리셋 값 0)
    `uvm_info("BITBASH", "pass 1: uvm_reg_bit_bash_seq on a zero background", UVM_LOW)  // 진행 로그
    bash0 = uvm_reg_bit_bash_seq::type_id::create("bit_bash_bg0");  // 내장 bit-bash 생성
    bash0.model = rm;                               // 대상 블록
    bash0.start(null, this);                        // frontdoor 접근은 map의 sequencer로 감

    // 2회차: 1 배경 (레지스터마다 single bit-bash. model.reset()을 부르지 않음)
    `uvm_info("BITBASH", "pass 2: uvm_reg_single_bit_bash_seq on an all-ones background", UVM_LOW)  // 진행 로그
    foreach (regs[i]) regs[i].write(status, 32'hFFFF_FFFF, .parent(this));  // 배경: 1을 모두 씀
    foreach (regs[i]) begin                         // 레지스터마다
      bash1 = uvm_reg_single_bit_bash_seq::type_id::create("bit_bash_bg1");  // 내장 single bit-bash 생성
      bash1.rg = regs[i];                           // 대상 레지스터
      bash1.start(null, this);                      // 배경 = rg.get()
    end                                             // foreach 끝
    foreach (regs[i]) regs[i].write(status, 0, .parent(this));  // 끝: 0으로 되돌림
  endtask                                           // body 끝
endclass                                            // 클래스 끝
