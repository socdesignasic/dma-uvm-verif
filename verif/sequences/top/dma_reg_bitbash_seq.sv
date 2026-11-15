// dma_reg_bitbash_seq : 모든 RW 레지스터에 walking-1 / walking-0을 쓰고 읽음.
// 구현된 비트 k마다 (1<<k)와 mask&~(1<<k)를 쓰고 다시 읽어 32비트 전체를
// 비교 (구현 안 된 비트는 0이어야 함). 끝나면 레지스터는 0으로 둠.
// AP_CTRL(ap_start를 쓰면 DMA가 시작됨)과 ISR(읽으면 지워짐)은 제외.
class dma_reg_bitbash_seq extends axil_base_seq;    // 레지스터 접근 기본 sequence 상속
  `uvm_object_utils(dma_reg_bitbash_seq)            // factory 등록

  function new(string name = "dma_reg_bitbash_seq");  // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    bit [11:0] addr[8] = '{ADDR_GIE, ADDR_IER,      // 검사할 레지스터 주소 8개
                           ADDR_RDMA_TRANSFER_BYTE, ADDR_RDMA_MEM_PTR,  // (주소 목록 계속)
                           ADDR_WDMA_TRANSFER_BYTE, ADDR_WDMA_MEM_PTR,  // (주소 목록 계속)
                           ADDR_AXI00_PTR0, ADDR_VALUE_TO_ADD};  // (주소 목록 끝)
    bit [31:0] mask[8] = '{32'h1, 32'h3, '1, '1, '1, '1, '1, '1};  // 레지스터별 구현된 비트 마스크 (GIE 1비트, IER 2비트, 나머지 32비트)
    bit [31:0] wv, rv;                              // 쓴 값, 읽은 값
    int unsigned n_checks, errs;                    // 검사 횟수, 불일치 수

    foreach (addr[r]) begin                         // 레지스터마다
      for (int k = 0; k < 32; k++) begin            // 비트마다
        if (!mask[r][k]) continue;                  // 구현 안 된 비트는 건너뜀
        for (int pass = 0; pass < 2; pass++) begin  // walking-1, walking-0 두 번
          wv = (pass == 0) ? (32'h1 << k) : (mask[r] & ~(32'h1 << k));  // 첫 번째는 k비트만 1, 두 번째는 k비트만 0
          write_reg(addr[r], wv);                   // 레지스터에 씀
          read_reg(addr[r], rv);                    // 다시 읽음
          n_checks++;                               // 검사 횟수 증가
          if (rv !== (wv & mask[r])) begin          // 읽은 값이 쓴 값(마스크 적용)과 다르면
            if (errs < 10)                          // 처음 10개만 보고
              `uvm_error("REG_BITBASH", $sformatf("0x%02h bit %0d: wrote 0x%08h, read 0x%08h, expected 0x%08h",  // 오류 보고
                                                  addr[r], k, wv, rv, wv & mask[r]))  // 메시지에 넣을 값들
            errs++;                                 // 불일치 수 증가
          end                                       // if 끝
        end                                         // pass 루프 끝
      end                                           // 비트 루프 끝
      write_reg(addr[r], 0);                        // 레지스터를 0으로 되돌림
    end                                             // 레지스터 루프 끝
    `uvm_info("REG_BITBASH", $sformatf("%0d registers, %0d write/read checks, %0d mismatches",  // 요약 로그
                                       $size(addr), n_checks, errs), UVM_LOW)  // 요약에 넣을 값들
  endtask                                           // body 끝
endclass                                            // 클래스 끝
