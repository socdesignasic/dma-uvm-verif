// dma_size_edge_test : cg_job.x_size_mode 커버리지 채우기: 정확한 경계 크기 x 두 가지 완료 방식.
//   1 beat (최소), 16 beat (burst 하나 가득), 512 beat (4KB 페이지 하나)
// 랜덤 크기로는 이 값들이 거의 나오지 않으므로 여기서 직접 지정함.
class dma_size_edge_test extends dma_base_test;
  `uvm_component_utils(dma_size_edge_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 6;
  endfunction

  virtual task run_jobs();
    int unsigned sizes[3] = '{1, 16, 512};
    for (int unsigned i = 0; i < n_jobs; i++) begin
      dma_job j = make_job(i);
      j.bytes = sizes[i % 3] * BEAT;
      j.mode  = (i < 3) ? DONE_POLL : DONE_IRQ;
      run_job(j);
    end
  endtask
endclass
