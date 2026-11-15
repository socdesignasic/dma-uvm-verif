// dma_env_cfg : env 설정값 (메모리 slave backpressure, 타임아웃용 클럭 주기)
class dma_env_cfg extends uvm_object;
  `uvm_object_utils(dma_env_cfg)
  axi4_slv_cfg slv_cfg;
  int unsigned clk_period_ns = 10;

  function new(string name = "dma_env_cfg");
    super.new(name);
    slv_cfg = axi4_slv_cfg::type_id::create("slv_cfg");
  endfunction
endclass
