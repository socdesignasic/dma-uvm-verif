// dma_reg_reset_test : 모든 레지스터가 리셋 값으로 읽히는지 확인 (dma_reg_reset_seq)
class dma_reg_reset_test extends dma_base_test;
  `uvm_component_utils(dma_reg_reset_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  virtual task run_jobs();
    dma_reg_reset_seq seq = dma_reg_reset_seq::type_id::create("seq");
    env.sb.expect_jobs = 0;
    seq.start(env.axil_agt.sqr);
  endtask
endclass
