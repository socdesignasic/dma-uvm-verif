// dma_job : DMA 실행 한 번 (원본, 대상, 크기, 더할 값, 완료 방식)
class dma_job extends uvm_object;
  `uvm_object_utils(dma_job)
  bit [31:0]  src, dst, bytes, value;
  done_mode_e mode;
  int unsigned id;

  function new(string name = "dma_job");
    super.new(name);
  endfunction

  function int unsigned beats(); return bytes / BEAT; endfunction
  function bit crosses_4k(bit [31:0] a); return (a >> 12) != ((a + bytes - 1) >> 12); endfunction

  virtual function string convert2string();
    return $sformatf("job#%0d src=0x%08h dst=0x%08h bytes=%0d (%0d beats) value=0x%08h mode=%s",
                     id, src, dst, bytes, beats(), value, mode.name());
  endfunction
endclass
