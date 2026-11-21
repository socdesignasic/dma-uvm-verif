// dma_reset_vseq : 테스트 중간 리셋 한 번 (virtual sequence, env.vsqr = dma_vsqr에서 실행).
//                  리셋 자극과, 리셋 동안 AXI-Lite 접근이 없었는지 검사(RESET_BUSY)를 담음
//   1. axil_sqr를 lock: 다른 sequence가 새 AXI-Lite 접근을 시작하지 못하게 함
//   2. lock은 driver가 이미 받은 item을 기다려 주지 않음 (UVM은 앞에 대기 요청이 없으면 바로 lock을 줌).
//      그래서 master 쪽 신호(AWVALID, WVALID, ARVALID, BREADY, RREADY)가 IDLE_EDGES 에지 연속 모두 0이 될 때까지 기다림
//      = 진행 중이던 접근이 B/R까지 끝남 (axil_driver는 접근하는 동안 이 중 하나를 항상 1로 둠 - 타이밍 노브(axil_cfg)가
//      0일 때만. 2 에지면 막 받은 item의 첫 구동이 다음 에지 +skew에 나타나는 경우도 잡음). max_wait 에지 안에 안 끝나면 RESET_BUSY
//      노브가 0이 아니면 AW/W 간격이나 READY 지연 동안 위 신호가 모두 0인 에지가 생기고, READY 지연 중에 리셋하면
//      driver가 오지 않는 B/R을 계속 기다리므로 시작하지 않음 -> RESET_CFG
//   3. rst_vif.pulse(n_cycles)와 나란히, DUT가 rst_n=0을 보는 에지(거는 에지 E 다음 E+1부터 해제 에지까지 n_cycles개)마다
//      AXI-Lite VALID(AWVALID, WVALID, ARVALID)를 검사해 1이면 RESET_BUSY. 특히 E+1은 DUT areset이 아직 0이라
//      접근을 받을 수 있는 에지. lock 밖에서 버스를 구동하거나 driver가 item 없이 VALID를 올리면 여기서 잡힘
//   4. 리셋이 풀린 뒤 post_cycles 에지 기다리고 unlock
//   메모리 모델은 건드리지 않음. AXI4 slave driver/monitor와 axil_monitor는 rst_n을 보고 스스로 리셋함
//   n_cycles >= 2: TB 쪽(monitor, predictor)은 해제 에지를 전원 리셋 때처럼 이미 리셋 밖으로 보므로 n-1 에지를 리셋으로 봄
//   (dma_reset_if 주석). 1이면 DUT만 리셋되고 monitor는 리셋을 못 봄 -> RESET_CFG
class dma_reset_vseq extends uvm_sequence #(uvm_sequence_item);  // virtual sequence (item을 직접 보내지 않음)
  `uvm_object_utils(dma_reset_vseq)                 // factory 등록
  `uvm_declare_p_sequencer(dma_vsqr)                // p_sequencer = dma_vsqr
  localparam int unsigned IDLE_EDGES = 2;           // AXI-Lite가 끝났다고 보는 연속 빈 에지 수

  int unsigned n_cycles    = 16;                    // DUT가 리셋을 보는 에지 수 (2 이상)
  int unsigned post_cycles = 5;                     // 리셋 해제 뒤 unlock 전 에지 수 (dma_base_test::wait_reset과 같음)
  int unsigned max_wait    = 1000;                  // 진행 중인 AXI-Lite 접근을 기다리는 최대 에지 수

  function new(string name = "dma_reset_vseq");     // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    axil_vif             c = p_sequencer.ctl_vif;   // AXI-Lite 신호 (표본은 moncb)
    virtual dma_reset_if r = p_sequencer.rst_vif;   // 리셋 interface
    int unsigned         idle, waited;              // 연속 빈 에지 수, 기다린 에지 수
    if (n_cycles < 2) `uvm_fatal("RESET_CFG", $sformatf("n_cycles=%0d: must be at least 2 (the TB sees n-1 reset edges)", n_cycles))  // 0/1이면 TB가 리셋을 못 봄
    if (p_sequencer.cfg.ctl_cfg.max_aw_w_skew != 0 || p_sequencer.cfg.ctl_cfg.max_ready_delay != 0)  // AXI-Lite 타이밍 노브를 켰으면 (위 2의 전제가 깨짐)
      `uvm_fatal("RESET_CFG", $sformatf("mid-test reset needs AXI-Lite timing knobs at 0 (%s): with AW/W skew or READY delay an access can be in progress with AWVALID/WVALID/ARVALID/BREADY/RREADY all low",  // 중단
                                        p_sequencer.cfg.ctl_cfg.convert2string()))  // 노브 값

    // 1. 새 접근 막기
    lock(p_sequencer.axil_sqr);                     // 다른 sequence의 AXI-Lite item을 막음

    // 2. 진행 중인 접근이 끝날 때까지
    while (idle < IDLE_EDGES) begin                 // 연속 빈 에지가 모자라면
      @(c.moncb);                                   // 다음 에지 (값은 에지 직전 표본)
      waited++;                                     // 기다린 에지 수
      if (c.moncb.awvalid === 1'b1 || c.moncb.wvalid === 1'b1 || c.moncb.arvalid === 1'b1 ||  // master가 접근 중이면
          c.moncb.bready  === 1'b1 || c.moncb.rready === 1'b1) idle = 0;  // (계속) 처음부터 셈
      else idle++;                                  // 빈 에지
      if (waited >= max_wait && idle < IDLE_EDGES)  // 너무 오래 걸리면
        `uvm_fatal("RESET_BUSY", $sformatf("AXI-Lite access still in progress after %0d cycles (AWVALID=%b WVALID=%b ARVALID=%b BREADY=%b RREADY=%b)",  // 중단
                                           waited, c.moncb.awvalid, c.moncb.wvalid, c.moncb.arvalid, c.moncb.bready, c.moncb.rready))  // 값들
    end                                             // while 끝

    // 3. 리셋 (지금 = 거는 에지 E. 이 에지까지는 위 루프가 빈 버스를 확인함)
    `uvm_info("RESET", $sformatf("reset asserted for %0d cycles (waited %0d cycles for AXI-Lite)", n_cycles, waited), UVM_LOW)  // 진행 로그
    fork                                            // 리셋과 리셋 중 검사를 나란히
      r.pulse(n_cycles);                            // 이 에지에서 0, n 에지 뒤 1
      for (int unsigned k = 1; k <= n_cycles; k++) begin  // DUT가 리셋을 보는 에지 E+1 .. 해제 에지
        @(c.moncb);                                 // 다음 에지 (값은 에지 직전 표본 = DUT가 그 에지에서 보는 값)
        if (c.moncb.awvalid === 1'b1 || c.moncb.wvalid === 1'b1 || c.moncb.arvalid === 1'b1)  // 리셋 중 AXI-Lite 접근
          `uvm_fatal("RESET_BUSY", $sformatf("AXI-Lite VALID high during reset, edge E+%0d of %0d (AWVALID=%b WVALID=%b ARVALID=%b)",  // 중단
                                             k, n_cycles, c.moncb.awvalid, c.moncb.wvalid, c.moncb.arvalid))  // 값들
      end                                           // for 끝
    join                                            // 둘 다 해제 에지에서 끝남

    // 4. 리셋 해제 뒤 풀어 줌
    repeat (post_cycles) @(c.moncb);                // 해제 뒤 기다림
    `uvm_info("RESET", "reset released, AXI-Lite unlocked", UVM_LOW)  // 진행 로그
    unlock(p_sequencer.axil_sqr);                   // AXI-Lite item 다시 허용
  endtask                                           // body 끝
endclass                                            // 클래스 끝
