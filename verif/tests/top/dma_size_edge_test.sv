// dma_size_edge_test : coverage closure for cg_job.x_size_mode: exact size edges x both completion modes.
//   1 beat (smallest), 16 beats (one full burst), 512 beats (one 4KB page)
// Random sizes almost never land on these single values, so they are directed here.
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
