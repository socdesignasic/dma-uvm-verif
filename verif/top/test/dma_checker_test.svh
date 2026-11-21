// dma_checker_test : checker self-test. 결함을 하나씩 일부러 넣고, 그 결함을 잡아야 하는 검사가 실제로 오류를 내는지 확인
//   주입 5종을 차례로 하나씩 켬 (job은 make_job(idx)로 1MB 창을 따로 씀). 레지스터 쓰기 전 읽기가 필요한 ④를 먼저 함:
//     ④ reg_reset       : 리셋 직후 uvm_reg_hw_reset_seq의 VALUE_TO_ADD 읽기 관찰값 bit31 (axil_monitor) -> REG_RESET
//     ① r_flip          : job 0의 첫 R beat 데이터 비트 하나 (axi4_slave_driver r_channel)          -> SB_WDATA, SB_DATA
//     ② r_addr          : job 1에서 R beat 하나를 같은 burst 안 이웃 8B에서 읽어 줌 (r_channel)    -> SB_WDATA, SB_DATA
//     ③ w_shift         : job 2의 마지막 쓰기 burst(끝 = dst + bytes)를 +8B 밀어 씀 (write_engine) -> SB_DATA, SB_OVERRUN
//     ⑤ reg_after_write : job 3의 첫 AP_CTRL 읽기 관찰값 bit31 (예약 비트, 앞 job에서 start를 쓴 뒤) -> REG_BITBASH
//   dma_error_catcher가 열린 창의 예상 ID만 UVM_INFO로 낮춤. 그 밖의 오류는 그대로 (테스트 FAIL).
//   끝에 예상 ID가 하나라도 0번이면 SELFTEST_MISS
//   +SELFTEST_NO_INJECT : 창은 열지만 주입하지 않음 (음성 대조: SELFTEST_MISS로 FAIL해야 함. 회귀에는 넣지 않음)
class dma_checker_test extends dma_base_test;       // 기본 테스트 상속
  `uvm_component_utils(dma_checker_test)            // factory 등록
  localparam int unsigned SETTLE = 10;              // 창을 닫기 전 기다리는 클럭 (analysis FIFO 뒤에서 늦게 나오는 보고까지 창 안에)

  dma_error_catcher catcher;                        // 예상 오류를 낮추는 catcher
  bit               no_inject;                      // +SELFTEST_NO_INJECT (음성 대조)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)

  virtual function void configure();                // 설정값 override
    n_jobs = 4; min_beats = 32; max_beats = 32;     // job 4개 (주입 ①②③⑤), 32 beat (2 beat 이상 burst가 있어 ②가 됨)
  endfunction                                       // configure 끝

  function void build_phase(uvm_phase phase);       // build 단계
    super.build_phase(phase);                       // 기본 테스트 build (env 생성)
    no_inject = $test$plusargs("SELFTEST_NO_INJECT");  // 음성 대조인지
    catcher = dma_error_catcher::type_id::create("catcher");  // catcher 생성
    uvm_report_cb::add(null, catcher);              // 모든 보고에 붙임 (이 테스트에서만)
  endfunction                                       // build_phase 끝

  virtual task run_jobs();                          // 주입 창 5개를 차례로
    uvm_reg_hw_reset_seq rst = uvm_reg_hw_reset_seq::type_id::create("hw_reset_seq");  // 내장 리셋 값 sequence
    dma_job              j;                         // job
    if (no_inject) `uvm_info("SELFTEST", "SELFTEST_NO_INJECT: windows are opened but nothing is injected (negative control)", UVM_LOW)  // 음성 대조 표시
    // ④ 쓰기 전 레지스터 읽기 관찰값 -> REG_RESET
    catcher.open("reg_reset", "REG_RESET");         // 창 열기
    if (!no_inject) inject_rd(ADDR_VALUE_TO_ADD);   // VALUE_TO_ADD 읽기 bit31
    rst.model = env.regmodel;                       // 대상 블록
    rst.start(null);                                // frontdoor로 레지스터 10개 읽기
    close_window();                                 // 창 닫기
    // ① R 데이터 비트 하나 -> SB_WDATA, SB_DATA
    j = make_job(0);                                // 1MB 창 0
    catcher.open("r_flip", "SB_WDATA", "SB_DATA");  // 창 열기
    if (!no_inject) cfg.slv_cfg.inj_r_flip = 1;     // 다음 R beat 하나
    run_job(j);                                     // 실행
    close_window();                                 // 창 닫기
    // ② 다른 주소 읽기 -> SB_WDATA, SB_DATA
    j = make_job(1);                                // 1MB 창 1
    catcher.open("r_addr", "SB_WDATA", "SB_DATA");  // 창 열기
    if (!no_inject) cfg.slv_cfg.inj_r_addr = 1;     // R beat 하나를 이웃 8B에서
    run_job(j);                                     // 실행
    close_window();                                 // 창 닫기
    // ③ 마지막 쓰기 burst를 +8B -> SB_DATA, SB_OVERRUN
    j = make_job(2);                                // 1MB 창 2
    catcher.open("w_shift", "SB_DATA", "SB_OVERRUN");  // 창 열기
    if (!no_inject) cfg.slv_cfg.inj_w_shift_end = j.dst + j.bytes;  // dst 끝에서 끝나는 burst
    run_job(j);                                     // 실행
    close_window();                                 // 창 닫기
    // ⑤ 쓴 뒤 레지스터 읽기 관찰값의 예약 비트 -> REG_BITBASH
    j = make_job(3);                                // 1MB 창 3
    catcher.open("reg_after_write", "REG_BITBASH");  // 창 열기
    if (!no_inject) inject_rd(ADDR_AP_CTRL);        // 첫 AP_CTRL 읽기 bit31 (idle 대기 읽기)
    run_job(j);                                     // 실행
    close_window();                                 // 창 닫기
  endtask                                           // run_jobs 끝

  function void inject_rd(bit [11:0] addr);         // 다음 addr 읽기 하나의 관찰값 bit31을 뒤집도록 axil_monitor 노브 설정
    env.axil_agt.mon.inj_rd_addr = addr;            // 주소
    env.axil_agt.mon.inj_rd_xor  = 32'h8000_0000;   // bit31
    env.axil_agt.mon.inj_rd_n    = 1;               // 한 번
  endfunction                                       // inject_rd 끝

  // 창 닫기: 늦게 오는 보고를 기다린 뒤, 쓰지 못한 노브는 끄고 (다음 창으로 새지 않게) catcher 창을 닫음
  task close_window();                              // 창 닫기
    env.clocks(SETTLE);                             // 기다림
    if (cfg.slv_cfg.inj_r_flip || cfg.slv_cfg.inj_r_addr || cfg.slv_cfg.inj_w_shift_end || env.axil_agt.mon.inj_rd_n)  // 남은 노브
      `uvm_info("SELFTEST", $sformatf("window %s: injection not used (r_flip=%0d r_addr=%0d w_shift_end=0x%08h rd_n=%0d)",  // 정보 (판정은 SELFTEST_MISS)
                                      catcher.inj, cfg.slv_cfg.inj_r_flip, cfg.slv_cfg.inj_r_addr,  // 값들
                                      cfg.slv_cfg.inj_w_shift_end, env.axil_agt.mon.inj_rd_n), UVM_LOW)  // (계속)
    cfg.slv_cfg.inj_r_flip      = 0;                // 끔
    cfg.slv_cfg.inj_r_addr      = 0;                // 끔
    cfg.slv_cfg.inj_w_shift_end = 0;                // 끔
    env.axil_agt.mon.inj_rd_n   = 0;                // 끔
    catcher.close();                                // 창 닫기
  endtask                                           // close_window 끝

  // 예상 ID가 한 번도 오지 않은 주입이 있으면 오류 (주입한 결함을 검사가 놓침)
  function void check_phase(uvm_phase phase);       // 검사 단계
    super.check_phase(phase);                       // 부모 검사 단계
    foreach (catcher.exp_id[k])                     // 예상 (주입, ID)마다
      if (catcher.exp_hits[k] == 0)                 // 한 번도 오지 않았으면
        `uvm_error("SELFTEST_MISS", $sformatf("injection %s: expected %s was never reported", catcher.exp_inj[k], catcher.exp_id[k]))  // 오류 보고
  endfunction                                       // check_phase 끝

  // [SELFTEST] 요약: 주입마다 예상 ID별 횟수, 예상 밖 오류 수
  function void report_phase(uvm_phase phase);      // 보고 단계
    string       line[string];                      // 주입 이름 -> " ID=n ..." 문자열
    string       order[$];                          // 주입 이름 순서
    string       n;                                 // 주입 이름
    string       ux;                                // 예상 밖 ID 목록 문자열
    string       mode;                              // 주입했는지 (음성 대조 표시)
    int unsigned miss;                              // 0번인 예상 (주입, ID) 수
    super.report_phase(phase);                      // 부모 보고 단계
    foreach (catcher.exp_id[k]) begin               // 예상 (주입, ID)마다
      n = catcher.exp_inj[k];                       // 주입 이름
      if (!line.exists(n)) begin                    // 처음 보는 주입이면
        order.push_back(n);                         // 순서 기록
        line[n] = "";                               // 문자열 시작
      end                                           // if 끝
      line[n] = {line[n], $sformatf(" %s=%0d", catcher.exp_id[k], catcher.exp_hits[k])};  // ID=횟수
      if (catcher.exp_hits[k] == 0) miss++;         // 0번
    end                                             // foreach 끝
    foreach (order[i])                              // 주입마다 한 줄
      `uvm_info("SELFTEST", $sformatf("injection %0d/%0d %s:%s", i + 1, order.size(), order[i], line[order[i]]), UVM_LOW)  // 요약 줄
    foreach (catcher.unexp[id]) ux = {ux, $sformatf(" %s=%0d", id, catcher.unexp[id])};  // 예상 밖 ID=수
    if (ux != "") ux = {" :", ux};                  // 있으면 앞에 구분 (XSim은 ?:의 문자열 상수를 폭에 맞춰 채우므로 if로)
    if (no_inject) mode = "SELFTEST_NO_INJECT";     // 음성 대조
    else           mode = "injected";               // 보통
    `uvm_info("SELFTEST", $sformatf("summary: injections=%0d expected ids=%0d missed=%0d | unexpected errors=%0d%s | %s",  // 요약 형식
                                    order.size(), catcher.exp_id.size(), miss, catcher.n_unexpected(), ux, mode), UVM_LOW)  // 수, 예상 밖 ID, 모드
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
