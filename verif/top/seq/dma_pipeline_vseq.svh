// dma_pipeline_vseq : idle 확인 없이 job을 잇달아 실행 (virtual sequence, env.vsqr에서 실행)
//   지금 job이 도는 동안 다음 job의 메모리와 레지스터를 미리 쓰고, 지금 job이 끝나면(done) 바로 다음 job을 start.
//     1. 첫 job: 메모리, 레지스터 전체, (wait_idle_before) idle 대기, start
//     2. job마다 동시에:
//        - 완료 대기: 자식 dma_job_vseq (do_wait만. 버스 접근을 이 vseq와 따로 중재하려고 자식으로 돌림)
//        - 다음 job 준비 (이 vseq): 지금 job의 m00 R handshake가 program_at_r개가 되면 다음 job 메모리(do_prep)와
//          레지스터(AXI00, 크기, 주소)를 씀. VALUE_TO_ADD는 value_at_r < 0이면 같이 쓰고,
//          아니면 그다음 R handshake가 value_at_r개가 될 때까지 기다렸다가 씀 (H3: 작업 중 VALUE 변경).
//          R 수가 그 job의 beat 수보다 크게 정해졌으면 beat 수(마지막 R 뒤)로 줄임
//     3. done 뒤: 다음 job의 GIE/IER가 지금과 다를 때만 그 둘을 쓰고, idle 확인 없이 바로 start
//     4. 마지막 job: (wait_idle_after) 다시 idle 대기
//   R handshake 수는 slave driver의 n_rd_beats로 셈 (읽기만. 지금 job start 직전 값과의 차이)
//   dma_job_vseq에서 물려받는 노브: do_prep, poison, gie, ier, start_value, done_wait와 그 설정(n_irq, ctrl_rd_delay, window_*),
//     wait_idle_before(첫 job에만), wait_idle_after(마지막 job에만). do_program/do_start/do_wait는 쓰지 않음
//   주의: 다음 job의 메모리를 지금 job 중에 쓰므로 job들의 src/dst/guard 범위는 서로 겹치지 않아야 함 (dma_base_test::make_job은 1MB 창).
//         지금 job 중 VALUE_TO_ADD[7:0]을 다른 값으로 바꾸면 지금 job의 뒤쪽 beat가 새 값으로 더해짐 (RTL 동작, H3)
class dma_pipeline_vseq extends dma_job_vseq;       // 단계 task와 노브를 물려받음
  `uvm_object_utils(dma_pipeline_vseq)              // factory 등록

  dma_job      jobs[$];                             // 차례로 실행할 job (start() 전에 test가 설정)
  int unsigned program_at_r = 1;                    // 다음 job 메모리와 레지스터를 쓰기 시작하는 지금 job의 R handshake 수
  int          value_at_r   = -1;                   // 다음 job VALUE_TO_ADD를 쓰는 지금 job의 R handshake 수 (-1: 다른 레지스터와 같이)

  protected dma_job_vseq cur_wait;                  // 지금 job의 완료 대기 자식 vseq
  protected bit          cur_over;                  // 그 자식이 끝났는지

  function new(string name = "dma_pipeline_vseq");  // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    dma_job      j, nxt;                            // 지금 job, 다음 job
    int unsigned r0;                                // 지금 job start 직전의 R handshake 수
    if (jobs.size() == 0) return;                   // 할 일 없음
    // 1. 첫 job
    j = jobs[0];                                    // 첫 job
    name_job(j);                                    // 번호와 시작 로그
    if (do_prep) prep_mem(j);                       // 메모리
    program_regs(j);                                // 레지스터 전체
    r0 = p_sequencer.mem_drv.n_rd_beats;            // start 직전 R 수
    start_dut(wait_idle_before);                    // start
    foreach (jobs[i]) begin                         // job마다
      j   = jobs[i];                                // 지금 job
      nxt = (i + 1 < jobs.size()) ? jobs[i + 1] : null;  // 다음 job (없으면 null)
      cur_wait = make_wait_vseq(j, nxt == null);    // 완료 대기 자식 vseq
      cur_over = 0;                                 // 아직 대기 중
      // 2. 완료 대기와 다음 job 준비를 동시에
      fork begin                                    // wait fork가 이 안의 스레드만 기다리도록 감쌈
        fork                                        // 완료 대기 (자식)
          begin                                     // 자식 스레드
            cur_wait.start(p_sequencer, this);      // 완료 대기 (마지막 job이면 idle 대기까지)
            cur_over = 1;                           // 끝남 표시
          end                                       // 자식 스레드 끝
        join_none                                   // 기다리지 않고 진행
        if (nxt != null) prepare_next(j, nxt, r0);  // 다음 job 준비 (이 vseq)
        wait fork;                                  // 완료 대기도 끝날 때까지
      end join                                      // 감싼 블록 끝
      if (cur_wait.timed_out) return;               // JOB_TIMEOUT이면 멈춤 (보고는 자식이 함)
      if (nxt == null) break;                       // 마지막 job이면 끝
      // 3. done 뒤 바로 다음 job start (GIE/IER는 다를 때만)
      if (gie_value(nxt) != gie_value(j)) wr(p_sequencer.regmodel.gie, gie_value(nxt));  // 전역 인터럽트
      if (ier_value(nxt) != ier_value(j)) wr(p_sequencer.regmodel.ier, ier_value(nxt));  // 인터럽트 종류
      r0 = p_sequencer.mem_drv.n_rd_beats;          // start 직전 R 수
      start_dut(0);                                 // idle 확인 없이 start
    end                                             // foreach 끝
  endtask                                           // body 끝

  // 지금 job j가 도는 동안 다음 job nxt의 메모리와 레지스터를 씀 (r0: j start 직전의 R 수)
  task prepare_next(dma_job j, dma_job nxt, int unsigned r0);  // 지금 job, 다음 job, 기준 R 수
    int unsigned k_prog;                            // 레지스터를 쓰기 시작할 R 수
    int unsigned k_val;                             // VALUE를 쓸 R 수
    int unsigned r_before;                          // VALUE 쓰기 직전 R 수
    k_prog = (program_at_r > j.beats()) ? j.beats() : program_at_r;  // beat 수 이하로
    wait_r(r0, k_prog);                             // 지금 job R handshake가 k_prog개가 될 때까지
    if (cur_wait.timed_out) return;                 // 지금 job이 JOB_TIMEOUT이면 준비하지 않음
    name_job(nxt);                                  // 다음 job 번호와 시작 로그
    if (do_prep) prep_mem(nxt);                     // 다음 job 메모리 (백도어)
    program_regs(nxt, value_at_r < 0, 0);           // 다음 job 레지스터 (GIE/IER는 done 뒤에 다를 때만)
    if (value_at_r < 0) return;                     // VALUE도 같이 썼으면 끝
    k_val = (value_at_r > int'(j.beats())) ? j.beats() : value_at_r;  // beat 수 이하로
    wait_r(r0, k_val);                              // R handshake가 k_val개가 될 때까지
    if (cur_wait.timed_out) return;                 // 지금 job이 JOB_TIMEOUT이면 쓰지 않음
    r_before = p_sequencer.mem_drv.n_rd_beats - r0; // 쓰기 직전 R 수
    wr(p_sequencer.regmodel.value_to_add, nxt.value);  // 다음 job 더할 값
    `uvm_info("PIPE", $sformatf("job#%0d running: VALUE_TO_ADD=0x%08h (job#%0d) written at R handshake %0d..%0d of %0d (asked %0d)",  // VALUE 쓰기 시점 로그
              j.id, nxt.value, nxt.id, r_before, p_sequencer.mem_drv.n_rd_beats - r0, j.beats(), value_at_r), UVM_LOW)  // 쓰기 전후 R 수 (기대값의 k는 dma_predictor가 W 에지로 셈)
  endtask                                           // prepare_next 끝

  // 지금 job의 R handshake 수(r0 기준)가 k개가 되거나 완료 대기가 끝날 때까지 대기
  task wait_r(int unsigned r0, int unsigned k);     // 기준 R 수, 목표 수
    while (p_sequencer.mem_drv.n_rd_beats - r0 < k && !cur_over) clocks(1);  // 한 클럭씩
  endtask                                           // wait_r 끝

  // 지금 job j의 완료 대기 자식 vseq를 만들고 노브를 옮김 (last: 마지막 job이면 wait_idle_after도)
  function dma_job_vseq make_wait_vseq(dma_job j, bit last);  // job, 마지막 job인지
    dma_job_vseq w = dma_job_vseq::type_id::create("wait_vseq");  // 자식 vseq
    w.job             = j;                          // 같은 job (번호는 이미 붙음)
    w.do_prep         = 0;                          // 메모리 안 씀
    w.do_program      = 0;                          // 레지스터 안 씀
    w.do_start        = 0;                          // start 안 씀
    w.do_wait         = 1;                          // 완료 대기만
    w.wait_idle_after = last && wait_idle_after;    // 마지막 job만 idle 대기
    w.done_wait       = done_wait;                  // 완료 대기 방식
    w.n_irq           = n_irq;                      // ISR_LOOP 인터럽트 수
    w.ctrl_rd_delay   = ctrl_rd_delay;              // IRQ/ISR_LOOP: AP_CTRL 읽기 전 대기
    w.window_cycles   = window_cycles;              // WINDOW 사이클 수
    w.window_poll     = window_poll;                // WINDOW 읽기 간격
    w.window_min_ar   = window_min_ar;              // WINDOW 최소 AR 수
    return w;                                       // 자식 vseq
  endfunction                                       // make_wait_vseq 끝
endclass                                            // 클래스 끝
