// dma_reg_bitbash_seq : 모든 RW 레지스터에 walking-1 / walking-0을 쓰고 읽음.
// 구현된 비트 k마다 (1<<k)와 mask&~(1<<k)를 쓰고 다시 읽어 32비트 전체를
// 비교 (구현 안 된 비트는 0이어야 함). 끝나면 레지스터는 0으로 둠.
// AP_CTRL(ap_start를 쓰면 DMA가 시작됨)과 ISR(읽으면 지워짐)은 제외.
class dma_reg_bitbash_seq extends axil_base_seq;
  `uvm_object_utils(dma_reg_bitbash_seq)

  function new(string name = "dma_reg_bitbash_seq");
    super.new(name);
  endfunction

  virtual task body();
    bit [11:0] addr[8] = '{ADDR_GIE, ADDR_IER,
                           ADDR_RDMA_TRANSFER_BYTE, ADDR_RDMA_MEM_PTR,
                           ADDR_WDMA_TRANSFER_BYTE, ADDR_WDMA_MEM_PTR,
                           ADDR_AXI00_PTR0, ADDR_VALUE_TO_ADD};
    bit [31:0] mask[8] = '{32'h1, 32'h3, '1, '1, '1, '1, '1, '1};
    bit [31:0] wv, rv;
    int unsigned n_checks, errs;

    foreach (addr[r]) begin
      for (int k = 0; k < 32; k++) begin
        if (!mask[r][k]) continue;
        for (int pass = 0; pass < 2; pass++) begin
          wv = (pass == 0) ? (32'h1 << k) : (mask[r] & ~(32'h1 << k));
          write_reg(addr[r], wv);
          read_reg(addr[r], rv);
          n_checks++;
          if (rv !== (wv & mask[r])) begin
            if (errs < 10)
              `uvm_error("REG_BITBASH", $sformatf("0x%02h bit %0d: wrote 0x%08h, read 0x%08h, expected 0x%08h",
                                                  addr[r], k, wv, rv, wv & mask[r]))
            errs++;
          end
        end
      end
      write_reg(addr[r], 0);
    end
    `uvm_info("REG_BITBASH", $sformatf("%0d registers, %0d write/read checks, %0d mismatches",
                                       $size(addr), n_checks, errs), UVM_LOW)
  endtask
endclass
