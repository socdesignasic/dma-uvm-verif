// dma_reg_bitbash_test : walking-1/0 write+read on every RW register (dma_reg_bitbash_seq)
class dma_reg_bitbash_test extends dma_base_test;
  `uvm_component_utils(dma_reg_bitbash_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  virtual task run_jobs();
    dma_reg_bitbash_seq seq = dma_reg_bitbash_seq::type_id::create("seq");
    env.sb.expect_jobs = 0;
    seq.start(env.axil_agt.sqr);
  endtask
endclass
