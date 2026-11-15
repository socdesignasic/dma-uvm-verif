// dma_aw_backpressure_test : BUG-002 재현. AWREADY를 막으면 W beat가 AW보다 먼저 나가고,
// WDMA burst 카운터가 그 beat를 놓쳐 WLAST가 늦게 나오며 ap_done이 끝내 오지 않음.
// 다른 테스트는 모두 AWREADY=1로 둬서 (verif/BUGS.md 참고) 나머지 기능은 계속 검증함.
class dma_aw_backpressure_test extends dma_base_test;
  `uvm_component_utils(dma_aw_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure();
    n_jobs = 1; min_beats = 64; max_beats = 64;
    cfg.slv_cfg.aw_fixed_wait = 40;   // W 데이터가 항상 AW 수락보다 먼저 준비됨
  endfunction
endclass
