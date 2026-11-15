// dma_reg_reset_seq : 리셋 직후 모든 레지스터를 읽어 32비트 전체를 리셋 값과 비교
// (AP_CTRL은 ap_idle=1만, 나머지는 모두 0, 사용하지 않는 비트는 0).
class dma_reg_reset_seq extends axil_base_seq;
  `uvm_object_utils(dma_reg_reset_seq)

  function new(string name = "dma_reg_reset_seq");
    super.new(name);
  endfunction

  virtual task body();
    bit [11:0] addr[10]  = '{ADDR_AP_CTRL, ADDR_GIE, ADDR_IER, ADDR_ISR,
                             ADDR_RDMA_TRANSFER_BYTE, ADDR_RDMA_MEM_PTR,
                             ADDR_WDMA_TRANSFER_BYTE, ADDR_WDMA_MEM_PTR,
                             ADDR_AXI00_PTR0, ADDR_VALUE_TO_ADD};
    bit [31:0] reset[10] = '{32'h1 << AP_IDLE, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    bit [31:0] v;
    int unsigned errs;

    foreach (addr[i]) begin
      read_reg(addr[i], v);
      if (v !== reset[i]) begin
        `uvm_error("REG_RESET", $sformatf("0x%02h: read 0x%08h, reset value 0x%08h", addr[i], v, reset[i]))
        errs++;
      end
    end
    `uvm_info("REG_RESET", $sformatf("%0d registers checked, %0d mismatches", $size(addr), errs), UVM_LOW)
  endtask
endclass
