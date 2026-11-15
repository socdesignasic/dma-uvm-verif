// dma_reg_reset_seq : 리셋 직후 모든 레지스터를 읽어 32비트 전체를 리셋 값과 비교
// (AP_CTRL은 ap_idle=1만, 나머지는 모두 0, 사용하지 않는 비트는 0).
class dma_reg_reset_seq extends axil_base_seq;      // 레지스터 접근 기본 sequence 상속
  `uvm_object_utils(dma_reg_reset_seq)              // factory 등록

  function new(string name = "dma_reg_reset_seq");  // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    bit [11:0] addr[10]  = '{ADDR_AP_CTRL, ADDR_GIE, ADDR_IER, ADDR_ISR,  // 검사할 레지스터 주소 10개
                             ADDR_RDMA_TRANSFER_BYTE, ADDR_RDMA_MEM_PTR,  // (주소 목록 계속)
                             ADDR_WDMA_TRANSFER_BYTE, ADDR_WDMA_MEM_PTR,  // (주소 목록 계속)
                             ADDR_AXI00_PTR0, ADDR_VALUE_TO_ADD};  // (주소 목록 끝)
    bit [31:0] reset[10] = '{32'h1 << AP_IDLE, 0, 0, 0, 0, 0, 0, 0, 0, 0};  // 리셋 값: AP_CTRL만 ap_idle=1, 나머지 0
    bit [31:0] v;                                   // 읽은 값
    int unsigned errs;                              // 불일치 수

    foreach (addr[i]) begin                         // 레지스터마다
      read_reg(addr[i], v);                         // 읽기
      if (v !== reset[i]) begin                     // 리셋 값과 다르면
        `uvm_error("REG_RESET", $sformatf("0x%02h: read 0x%08h, reset value 0x%08h", addr[i], v, reset[i]))  // 오류 보고
        errs++;                                     // 불일치 수 증가
      end                                           // if 끝
    end                                             // foreach 끝
    `uvm_info("REG_RESET", $sformatf("%0d registers checked, %0d mismatches", $size(addr), errs), UVM_LOW)  // 요약 로그
  endtask                                           // body 끝
endclass                                            // 클래스 끝
