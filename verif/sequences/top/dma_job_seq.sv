// dma_job_seq : DMA 작업 하나를 처음부터 끝까지 실행하고 검사받음
//   1. 메모리: 원본은 랜덤, 앞뒤 보호 영역, 대상은 ~기대값으로 미리 오염
//   2. 레지스터 설정 (SW/mem_copy_test.c와 같은 순서), idle 대기, ap_start
//   3. AP_CTRL polling 또는 인터럽트로 완료 대기. 시간 제한 있음
//   4. scoreboard 검사 + coverage 샘플링, 다시 idle 대기
class dma_job_seq extends axil_base_seq;            // 레지스터 접근 기본 sequence 상속
  `uvm_object_utils(dma_job_seq)                    // factory 등록
  dma_env env;      // start() 전에 test가 설정
  dma_job job;      // start() 전에 test가 설정

  static int unsigned next_id;                      // 작업 번호 생성용 (모든 인스턴스가 공유)

  function new(string name = "dma_job_seq");        // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    axi4_mem         mem = env.mem_agt.mem;         // 메모리 모델 핸들
    bit [7:0]        snap[];                        // 원본 데이터 사본
    bit [7:0]        guard_val = 8'hA5;             // 보호 영역 바이트 값
    bit [31:0]       v;                             // 레지스터 읽기 값
    longint unsigned budget_ns;                     // 완료 대기 시간 한도 (ns)
    bit              timed_out;                     // 시간 초과 표시

    job.id = next_id++;                             // 작업 번호 붙이기
    `uvm_info("JOB", {"start ", job.convert2string()}, UVM_LOW)  // 작업 시작 로그

    // 1. 메모리
    snap = new[job.bytes];                          // 원본 크기만큼 사본 배열 할당
    foreach (snap[i]) begin                         // 원본 바이트마다
      snap[i] = $urandom;                           // 랜덤 값
      mem.wr8(job.src + i, snap[i]);                // 메모리 원본 위치에 씀
    end                                             // foreach 끝
    for (int unsigned g = 1; g <= GUARD; g++) begin  // 보호 영역 바이트마다
      mem.wr8(job.dst - g, guard_val);              // dst 앞에 보호 값
      mem.wr8(job.dst + job.bytes - 1 + g, guard_val);  // dst 뒤에 보호 값
    end                                             // for 끝
    foreach (snap[i])                               // 대상 바이트마다
      mem.wr8(job.dst + i, ~dma_scoreboard::model_byte(snap[i], job.value));  // 기대값의 반전값으로 채움 (안 쓰면 반드시 틀림)
    env.sb.start_job(job);                          // scoreboard에 작업 시작 알림

    // 2. 설정 + 시작
    write_reg(ADDR_AXI00_PTR0,         0);          // AXI00 포인터 0
    write_reg(ADDR_VALUE_TO_ADD,       job.value);  // 더할 값
    write_reg(ADDR_RDMA_TRANSFER_BYTE, job.bytes);  // RDMA 바이트 수
    write_reg(ADDR_RDMA_MEM_PTR,       job.src);    // RDMA 원본 주소
    write_reg(ADDR_WDMA_TRANSFER_BYTE, job.bytes);  // WDMA 바이트 수
    write_reg(ADDR_WDMA_MEM_PTR,       job.dst);    // WDMA 대상 주소
    write_reg(ADDR_GIE, job.mode == DONE_IRQ);      // 인터럽트 모드면 전역 인터럽트 켬
    write_reg(ADDR_IER, job.mode == DONE_IRQ ? 2'b01 : 2'b00);  // 인터럽트 모드면 ap_done 인터럽트 켬
    do read_reg(ADDR_AP_CTRL, v); while (!v[AP_IDLE]);  // idle이 될 때까지 AP_CTRL polling
    write_reg(ADDR_AP_CTRL, 1 << AP_START);         // ap_start 씀

    // 3. 완료 대기
    budget_ns = 20000 + longint'(job.beats()) * env.cfg.clk_period_ns *  // 시간 한도 = 20us + beat 수 x 클럭 주기 x (8 + 지연 상한) x 4
                (8 + env.cfg.slv_cfg.max_r_latency + env.cfg.slv_cfg.max_b_latency) * 4;  // (위 식 계속)
    fork                                            // 완료 대기와 시간 제한을 병렬로
      begin                                         // 완료 대기 쪽
        if (job.mode == DONE_IRQ) begin             // 인터럽트 모드면
          wait (env.ctl_vif.interrupt === 1'b1);    // 인터럽트 신호가 1이 될 때까지 대기
          read_reg(ADDR_ISR, v);                    // ISR 읽기 (읽으면 지워짐)
          if (v[ISR_AP_DONE] !== 1'b1) `uvm_error("IRQ", $sformatf("ISR=0x%0h, ap_done bit not set", v))  // ap_done 비트가 없으면 오류
          env.clocks(3);                            // 3클럭 대기
          if (env.ctl_vif.interrupt !== 1'b0) `uvm_error("IRQ", "interrupt still high after ISR read")  // ISR을 읽었는데 인터럽트가 그대로면 오류
          read_reg(ADDR_AP_CTRL, v);                // AP_CTRL 읽기
          if (v[AP_DONE] !== 1'b1) `uvm_error("IRQ", "AP_CTRL.done not set on interrupt")  // done 비트가 없으면 오류
        end else begin                              // polling 모드면
          do read_reg(ADDR_AP_CTRL, v); while (!v[AP_DONE]);        // done polling (읽으면 지워짐)
          if (env.ctl_vif.interrupt !== 1'b0) `uvm_error("IRQ", "interrupt asserted with GIE=0")  // GIE=0인데 인터럽트가 나오면 오류
        end                                         // if 끝
      end                                           // 완료 대기 쪽 끝
      begin                                         // 시간 제한 쪽
        #(budget_ns * 1ns);                         // 한도만큼 대기
        timed_out = 1;                              // 시간 초과 표시
      end                                           // 시간 제한 쪽 끝
    join_any                                        // 둘 중 하나가 끝나면 진행
    disable fork;                                   // 남은 쪽 종료
    if (timed_out) begin                            // 시간 초과였으면
      `uvm_error("JOB_TIMEOUT", $sformatf("%s: not done after %0d ns (rd beats=%0d wr beats=%0d)",  // 타임아웃 오류 보고
                 job.convert2string(), budget_ns, env.mem_agt.drv.n_rd_beats, env.mem_agt.drv.n_wr_beats))  // 메시지에 넣을 값들 (지금까지 읽고 쓴 beat 수)
      return;                                       // 검사하지 않고 끝냄
    end                                             // if 끝

    // 4. 검사 (쓰기 응답은 이미 다 옴. 버스가 조용해질 때까지 먼저 기다림)
    env.clocks(5);                                  // 5클럭 대기
    env.sb.check_job(job, snap, guard_val);         // scoreboard 검사
    env.cov.sample_job(job);                        // coverage 샘플링
    do read_reg(ADDR_AP_CTRL, v); while (!v[AP_IDLE]);       // 다시 idle
  endtask                                           // body 끝
endclass                                            // 클래스 끝
