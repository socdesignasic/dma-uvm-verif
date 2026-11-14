// dma_reg_bitbash_seq : walking-1 / walking-0 write+read on every RW register.
// For each implemented bit k: write (1<<k) and mask&~(1<<k), read back, compare all
// 32 bits (unimplemented bits must read 0). Registers are left at 0.
// AP_CTRL (writing ap_start launches the DMA) and ISR (clear on read) are excluded.
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
