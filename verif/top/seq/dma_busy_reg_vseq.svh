// dma_busy_reg_vseq : 작업 중 레지스터 10개 쓰기와 다시 읽기 (virtual sequence, env.vsqr에서 실행). 자극만 담음
//   지금 job이 도는 동안 부름 (시점은 test가 정함). job = 다음 job (지금 job이 아님):
//     1. (do_prep) 다음 job 메모리 (백도어)
//     2. 데이터 레지스터 6개와 GIE/IER = 다음 job 값 (program_regs: AXI00, VALUE, RDMA 크기/주소, WDMA 크기/주소, GIE, IER.
//        GIE/IER는 노브 gie/ier 또는 job.mode)
//     3. ISR = isr_value (RC: 쓰기는 무시돼야 함), AP_CTRL = ctrl_value (기본 0x00: start=0, auto_restart=0)
//     4. 레지스터 10개를 모두 다시 읽음
//   검사는 monitor를 보는 쪽이 함: 읽기값 -> dma_predictor (데이터 레지스터, GIE, IER = 쓴 값 / ISR, AP_CTRL = 사이클 모델),
//     크기와 주소가 지금 job에 영향이 없는지 -> dma_scoreboard (지금 job은 PRE 시점 shadow, 다음 job은 여기서 쓴 값으로 검사)
//   VALUE_TO_ADD[7:0]을 지금 값과 다르게 쓰면 지금 job의 뒤쪽 beat가 새 값으로 더해짐 (RTL 동작, H3. dma_predictor가 beat별로 예측)
//   dma_job_vseq에서 물려받아 쓰는 것: do_prep, gie, ier, 단계 task (prep_mem, program_regs, wr, rd).
//   do_program/do_start/do_wait와 완료 대기 노브는 쓰지 않음
class dma_busy_reg_vseq extends dma_job_vseq;       // 단계 task와 노브를 물려받음
  `uvm_object_utils(dma_busy_reg_vseq)              // factory 등록

  bit [31:0] isr_value  = 32'h3;                    // ISR에 쓸 값 (ISR은 RC라 무시돼야 함)
  bit [31:0] ctrl_value = 32'h0;                    // AP_CTRL에 쓸 값 (start=0: 지금 job에 영향 없어야 함)

  function new(string name = "dma_busy_reg_vseq");  // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    dma_reg_block rm = p_sequencer.regmodel;        // RAL 모델 핸들
    uvm_reg       regs[$];                          // 다시 읽을 레지스터 (주소 순서)
    bit [31:0]    v;                                // 읽기 값
    name_job(job);                                  // 다음 job 번호와 시작 로그 (처음이면)
    if (do_prep) prep_mem(job);                     // 1. 다음 job 메모리
    program_regs(job);                              // 2. 데이터 레지스터 6개 + GIE/IER (8개)
    wr(rm.isr,     isr_value);                      // 3. ISR (9번째, 무시돼야 함)
    wr(rm.ap_ctrl, ctrl_value);                     //    AP_CTRL (10번째)
    regs.push_back(rm.ap_ctrl);            regs.push_back(rm.gie);           // 4. 10개 (0x00..0x24)
    regs.push_back(rm.ier);                regs.push_back(rm.isr);           // (계속)
    regs.push_back(rm.rdma_transfer_byte); regs.push_back(rm.rdma_mem_ptr);  // (계속)
    regs.push_back(rm.wdma_transfer_byte); regs.push_back(rm.wdma_mem_ptr);  // (계속)
    regs.push_back(rm.axi00_ptr0);         regs.push_back(rm.value_to_add);  // (계속)
    foreach (regs[i]) rd(regs[i], v);               // 다시 읽기 (값은 dma_predictor가 비교)
    `uvm_info("BUSY_REG", $sformatf("wrote 10 registers (values of %s, ISR=0x%08h, AP_CTRL=0x%08h) and read them back",  // 진행 로그
                                    job.convert2string(), isr_value, ctrl_value), UVM_LOW)  // 값들
  endtask                                           // body 끝
endclass                                            // 클래스 끝
