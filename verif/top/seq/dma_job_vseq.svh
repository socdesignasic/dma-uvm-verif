// dma_job_vseq : DMA 작업 하나를 처음부터 끝까지 실행 (virtual sequence, env.vsqr = dma_vsqr에서 실행)
//   단계 (노브 do_*로 켜고 끔. 같은 job을 단계별로 여러 vseq에 나눠 실행해도 됨. 번호는 처음 만진 vseq가 한 번만 붙임):
//   1. do_prep    : 메모리 (백도어): 원본은 랜덤, 앞뒤 보호 영역, 대상은 ~기대값으로 미리 오염 (poison. src와 dst가 겹치면 끔)
//   2. do_program : 레지스터 설정 (SW/mem_copy_test.c와 같은 순서). GIE/IER 값은 노브 gie/ier (기본: job.mode)
//   3. do_start   : (wait_idle_before) idle 대기, AP_CTRL = start_value
//   4. do_wait    : done_wait 방식으로 완료 대기. 시간 제한 있음 (JOB_TIMEOUT). 그다음 (wait_idle_after) 다시 idle 대기
//        POLL_DONE : done이 1이 될 때까지 AP_CTRL polling
//        IRQ       : 인터럽트 -> ISR 읽기 -> ctrl_rd_delay클럭(기본 3) -> AP_CTRL 읽기
//        ISR_LOOP  : n_irq번 (인터럽트 -> ISR 읽기 -> 인터럽트 내려감), 그다음 ctrl_rd_delay클럭 -> AP_CTRL 읽기. 시간 한도도 n_irq배
//        WINDOW    : window_cycles 사이클 동안 window_poll 사이클마다 AP_CTRL 읽기 (완료를 기다리지 않음).
//                    창 안 m00 AR handshake가 window_min_ar보다 적으면 JOB_TIMEOUT
//        WAIT_BY_MODE (기본): job.mode가 DONE_IRQ면 IRQ, 아니면 POLL_DONE
//   기본 노브에서는 단계로 나누기 전과 같은 AXI-Lite 접근을 같은 순서, 같은 시각에 냄.
//   자극과 liveness 시간 제한(JOB_TIMEOUT)만 담음. 검사는 monitor를 보는 쪽이 함:
//     읽기값(ISR[0], AP_CTRL.done 등)과 interrupt 핀 -> dma_predictor, 버스와 메모리 -> dma_scoreboard
//   레지스터는 regmodel.<reg>.write/read (frontdoor): uvm_reg_map이 adapter로 만든 axil_item을 AXI4-Lite sequencer로 보냄.
//   mirror는 monitor 경로(axil_monitor -> dma_predictor -> uvm_reg_predictor)로만 갱신됨 (auto predict 끔).
//   응답 코드는 axil_monitor가 모든 접근에서 검사 (AXIL_RESP)
class dma_job_vseq extends uvm_sequence #(uvm_sequence_item);  // virtual sequence (item을 직접 보내지 않음)
  `uvm_object_utils(dma_job_vseq)                   // factory 등록
  `uvm_declare_p_sequencer(dma_vsqr)                // p_sequencer = dma_vsqr

  typedef enum {WAIT_BY_MODE, POLL_DONE, IRQ, ISR_LOOP, WINDOW} done_wait_e;  // 완료 대기 방식 (위 설명)

  dma_job job;      // start() 전에 test가 설정

  // ---- 노브 (기본값 = 단계로 나누기 전 동작) ----
  bit          do_prep          = 1;                // 1. 메모리 준비
  bit          do_program       = 1;                // 2. 레지스터 설정
  bit          do_start         = 1;                // 3. 시작
  bit          do_wait          = 1;                // 4. 완료 대기
  bit          poison           = 1;                // dst 본체를 ~기대값으로 미리 채움 (src와 dst가 겹치는 in-place job이면 자동으로 끔)
  bit          wait_idle_before = 1;                // start 전에 AP_CTRL.idle polling
  bit          wait_idle_after  = 1;                // 완료 뒤 5클럭 쉬고 AP_CTRL.idle polling
  int          gie              = -1;               // GIE에 쓸 값 (-1: job.mode == DONE_IRQ면 1, 아니면 0)
  int          ier              = -1;               // IER에 쓸 값 (-1: job.mode == DONE_IRQ면 1(ap_done), 아니면 0)
  bit [31:0]   start_value      = 32'h1 << AP_START;  // do_start에서 AP_CTRL에 쓸 값
  done_wait_e  done_wait        = WAIT_BY_MODE;     // 완료 대기 방식
  int unsigned n_irq            = 1;                // ISR_LOOP: 기다릴 인터럽트 수
  int unsigned ctrl_rd_delay    = 3;                // IRQ/ISR_LOOP: 마지막 ISR 읽기(ISR_LOOP는 인터럽트 하강) 뒤 AP_CTRL 읽기까지 클럭
                                                    // (가설 테스트는 predictor의 대기 start 사이클(TB 정의)에 기대지 않도록 16 이상)
  int unsigned window_cycles    = 0;                // WINDOW: 관찰 사이클 수
  int unsigned window_poll      = 0;                // WINDOW: AP_CTRL 읽기 간격 (사이클, 0이면 읽지 않음)
  int unsigned window_min_ar    = 0;                // WINDOW: 창 안 AR handshake 최소 수 (미달이면 JOB_TIMEOUT)

  // ---- 결과 ----
  bit          timed_out;                           // wait_done이 JOB_TIMEOUT을 냈는지 (dma_pipeline_vseq가 봄)

  static int unsigned next_id;                      // 작업 번호 생성용 (모든 인스턴스가 공유)
  static dma_job      named[$];                     // 번호를 붙인 job (단계를 나눠 실행해도 번호는 한 번만)

  function new(string name = "dma_job_vseq");       // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual task body();                              // sequence 본문
    name_job(job);                                  // 작업 번호 붙이기 (처음이면)
    if (do_prep)    prep_mem(job);                  // 1. 메모리 (백도어)
    if (do_program) program_regs(job);              // 2. 레지스터 설정
    if (do_start)   start_dut(wait_idle_before);    // 3. 시작
    if (do_wait) begin                              // 4. 완료 대기
      wait_done(job);                               // done_wait 방식
      if (!timed_out && wait_idle_after) wait_idle();  // 시간 초과면 검사하지 않고 끝냄, 아니면 다시 idle
    end                                             // if 끝
  endtask                                           // body 끝

  // job에 번호를 붙이고 시작 로그 (이미 붙인 job이면 아무것도 안 함)
  function void name_job(dma_job j);                // job
    int q[$];                                       // 찾은 위치
    q = named.find_first_index(x) with (x == j);    // 이미 번호를 붙였는지
    if (q.size() > 0) return;                       // 붙였으면 끝
    named.push_back(j);                             // 기억
    j.id = next_id++;                               // 작업 번호 붙이기
    `uvm_info("JOB", {"start ", j.convert2string()}, UVM_LOW)  // 작업 시작 로그
  endfunction                                       // name_job 끝

  // src와 dst 범위가 겹치는지 (in-place). 겹치면 pre-poison이 src를 덮으므로 하지 않음
  function bit in_place(dma_job j);                 // job
    longint unsigned s = j.src, d = j.dst, n = j.bytes;  // 넘침 없이 비교하도록 64비트로
    return (d < s + n) && (s < d + n);              // 두 구간이 겹침
  endfunction                                       // in_place 끝

  // 1. 메모리 (백도어): src 랜덤, dst 앞뒤 guard, dst 본체 pre-poison
  function void prep_mem(dma_job j);                // job
    axi4_mem   mem = p_sequencer.mem;               // 메모리 모델 핸들 (백도어)
    bit [7:0]  snap[];                              // 원본 데이터 사본
    bit [7:0]  guard_val = 8'hA5;                   // 보호 영역 바이트 값
    snap = new[j.bytes];                            // 원본 크기만큼 사본 배열 할당
    foreach (snap[i]) begin                         // 원본 바이트마다
      snap[i] = $urandom;                           // 랜덤 값
      mem.wr8(j.src + i, snap[i]);                  // 메모리 원본 위치에 씀
    end                                             // foreach 끝
    for (int unsigned g = 1; g <= GUARD; g++) begin  // 보호 영역 바이트마다
      mem.wr8(j.dst - g, guard_val);                // dst 앞에 보호 값
      mem.wr8(j.dst + j.bytes - 1 + g, guard_val);  // dst 뒤에 보호 값
    end                                             // for 끝
    if (!poison) return;                            // pre-poison을 끈 경우
    if (in_place(j)) begin                          // src와 dst가 겹치면
      `uvm_info("JOB", $sformatf("job#%0d: src and dst overlap (in-place), dst is not pre-poisoned", j.id), UVM_MEDIUM)  // 끈 이유
      return;                                       // pre-poison 하지 않음
    end                                             // if 끝
    foreach (snap[i])                               // 대상 바이트마다
      mem.wr8(j.dst + i, ~dma_ref_model::model_byte(snap[i], j.value));  // 기대값의 반전값으로 채움 (안 쓰면 반드시 틀림)
  endfunction                                       // prep_mem 끝

  // 2. 레지스터 설정 (순서는 SW/mem_copy_test.c와 같음). with_value=0이면 VALUE_TO_ADD, with_irq=0이면 GIE/IER를 쓰지 않음
  task program_regs(dma_job j, bit with_value = 1, bit with_irq = 1);  // job, VALUE_TO_ADD를 쓸지, GIE/IER를 쓸지
    dma_reg_block rm = p_sequencer.regmodel;        // RAL 모델 핸들
    wr(rm.axi00_ptr0,         0);                   // AXI00 포인터 0
    if (with_value) wr(rm.value_to_add, j.value);   // 더할 값
    wr(rm.rdma_transfer_byte, j.bytes);             // RDMA 바이트 수
    wr(rm.rdma_mem_ptr,       j.src);               // RDMA 원본 주소
    wr(rm.wdma_transfer_byte, j.bytes);             // WDMA 바이트 수
    wr(rm.wdma_mem_ptr,       j.dst);               // WDMA 대상 주소
    if (with_irq) begin                             // 인터럽트 설정
      wr(rm.gie, gie_value(j));                     // 전역 인터럽트
      wr(rm.ier, ier_value(j));                     // 인터럽트 종류
    end                                             // if 끝
  endtask                                           // program_regs 끝

  function bit [31:0] gie_value(dma_job j);         // GIE에 쓸 값
    return (gie >= 0) ? gie : (j.mode == DONE_IRQ);  // 노브 또는 job.mode
  endfunction                                       // gie_value 끝

  function bit [31:0] ier_value(dma_job j);         // IER에 쓸 값
    return (ier >= 0) ? ier : (j.mode == DONE_IRQ ? 2'b01 : 2'b00);  // 노브 또는 job.mode (ap_done)
  endfunction                                       // ier_value 끝

  // 3. 시작: idle_first면 idle이 될 때까지 AP_CTRL polling, 그다음 AP_CTRL = start_value
  task start_dut(bit idle_first);                   // start 전에 idle을 기다릴지
    dma_reg_block rm = p_sequencer.regmodel;        // RAL 모델 핸들
    bit [31:0]    v;                                // 레지스터 읽기 값
    if (idle_first)                                 // idle 확인
      do rd(rm.ap_ctrl, v); while (!v[AP_IDLE]);    // idle이 될 때까지 AP_CTRL polling
    wr(rm.ap_ctrl, start_value);                    // ap_start 씀
  endtask                                           // start_dut 끝

  // 4. 완료 대기 (done_wait 방식). 시간 한도 안에 끝나지 않으면(WINDOW는 AR이 모자라면) JOB_TIMEOUT, timed_out = 1
  task wait_done(dma_job j);                        // job
    dma_reg_block    rm  = p_sequencer.regmodel;    // RAL 모델 핸들
    done_wait_e      how = done_wait;               // 이번 대기 방식
    bit [31:0]       v;                             // 레지스터 읽기 값
    longint unsigned budget_ns;                     // 완료 대기 시간 한도 (ns)
    bit              late;                          // 시간 한도에 걸림
    int unsigned     n_ar;                          // WINDOW: 창 안 AR handshake 수
    timed_out = 0;                                  // 결과 초기화
    if (how == WAIT_BY_MODE) how = (j.mode == DONE_IRQ) ? IRQ : POLL_DONE;  // job.mode로 고름
    if (how == WINDOW) begin                        // 정해진 창만 관찰
      watch_window(n_ar);                           // 창 동안 AR 세기 + AP_CTRL 읽기
      if (n_ar < window_min_ar)                     // AR이 모자라면
        job_timeout(j, $sformatf("%0d AR handshake(s) in a %0d-cycle window, expected at least %0d", n_ar, window_cycles, window_min_ar));  // 보고
      return;                                       // 창 끝
    end                                             // if 끝
    budget_ns = 20000 + longint'(j.beats()) * p_sequencer.cfg.clk_period_ns *  // 시간 한도 = 20us + beat 수 x 클럭 주기 x (8 + 지연 상한) x 4
                (8 + p_sequencer.cfg.slv_cfg.max_r_latency + p_sequencer.cfg.slv_cfg.max_b_latency) * 4;  // (위 식 계속)
    if (how == ISR_LOOP) budget_ns *= n_irq;        // 인터럽트 n_irq번이면 한도도 n_irq배
    fork begin                                      // disable fork가 이 안의 두 스레드만 끝내도록 감쌈
      fork                                          // 완료 대기와 시간 제한을 병렬로
        begin                                       // 완료 대기 쪽
          case (how)                                // 방식마다
            IRQ: begin                              // 인터럽트 한 번
              wait (p_sequencer.ctl_vif.interrupt === 1'b1);  // 인터럽트 신호가 1이 될 때까지 대기
              rd(rm.isr, v);                        // ISR 읽기 (읽으면 지워짐. ISR[0]과 interrupt 하강은 dma_predictor가 비교)
              clocks(ctrl_rd_delay);                // AP_CTRL 읽기 전 대기 (기본 3클럭)
              rd(rm.ap_ctrl, v);                    // AP_CTRL 읽기 (done은 dma_predictor가 비교)
            end                                     // IRQ 끝
            ISR_LOOP: begin                         // 인터럽트 n_irq번
              repeat (n_irq) begin                  // 인터럽트마다
                wait (p_sequencer.ctl_vif.interrupt === 1'b1);  // 인터럽트 대기
                rd(rm.isr, v);                      // ISR 읽기 (지워짐)
                wait (p_sequencer.ctl_vif.interrupt !== 1'b1);  // 인터럽트가 내려갈 때까지 (같은 인터럽트를 두 번 세지 않도록)
              end                                   // repeat 끝
              clocks(ctrl_rd_delay);                // AP_CTRL 읽기 전 대기 (기본 3클럭)
              rd(rm.ap_ctrl, v);                    // AP_CTRL 읽기
            end                                     // ISR_LOOP 끝
            default: begin                          // POLL_DONE
              do rd(rm.ap_ctrl, v); while (!v[AP_DONE]);  // done polling (읽으면 지워짐. GIE=0일 때 interrupt=0은 dma_predictor가 매 사이클 비교)
            end                                     // POLL_DONE 끝
          endcase                                   // case 끝
        end                                         // 완료 대기 쪽 끝
        begin                                       // 시간 제한 쪽
          #(budget_ns * 1ns);                       // 한도만큼 대기
          late = 1;                                 // 시간 초과 표시
        end                                         // 시간 제한 쪽 끝
      join_any                                      // 둘 중 하나가 끝나면 진행
      disable fork;                                 // 남은 쪽 종료
    end join                                        // 감싼 블록 끝
    if (late)                                       // 시간 초과였으면
      job_timeout(j, $sformatf("not done after %0d ns", budget_ns));  // 보고
  endtask                                           // wait_done 끝

  // WINDOW: window_cycles 사이클 동안 m00 AR handshake를 세고, window_poll 사이클마다 AP_CTRL을 읽음.
  //   AR은 m00 interface의 monitor clocking block으로 셈 (읽기만). 창이 끝날 때 진행 중인 AP_CTRL 읽기는 끝까지 함
  task watch_window(output int unsigned n_ar);      // 창 안 AR handshake 수
    axi4_vif      mv = p_sequencer.mem_drv.vif;     // m00 interface (읽기만)
    dma_reg_block rm = p_sequencer.regmodel;        // RAL 모델 핸들
    bit [31:0]    v;                                // 레지스터 읽기 값
    bit           over;                             // 창이 끝남
    n_ar = 0;                                       // 초기화
    fork                                            // 세기와 읽기를 병렬로 (둘 다 끝날 때까지)
      begin                                         // AR 세기
        repeat (window_cycles) begin                // 창의 에지마다
          @(mv.moncb);                              // 다음 에지 (값은 에지 직전 표본)
          if (mv.moncb.arvalid === 1'b1 && mv.moncb.arready === 1'b1) n_ar++;  // AR handshake
        end                                         // repeat 끝
        over = 1;                                   // 창 끝
      end                                           // AR 세기 끝
      if (window_poll > 0)                          // AP_CTRL 읽기를 켰으면
        while (!over) begin                         // 창이 끝날 때까지
          for (int unsigned c = 0; c < window_poll && !over; c++) clocks(1);  // 간격만큼 대기 (창이 끝나면 멈춤)
          if (!over) rd(rm.ap_ctrl, v);             // AP_CTRL 읽기 (값은 dma_predictor가 비교)
        end                                         // while 끝
    join                                            // fork 끝
  endtask                                           // watch_window 끝

  // JOB_TIMEOUT 보고 (이 vseq의 JOB_TIMEOUT은 모두 이 줄 하나로 냄). why: 무엇이 모자랐는지
  function void job_timeout(dma_job j, string why); // job, 이유
    timed_out = 1;                                  // 결과
    `uvm_error("JOB_TIMEOUT", $sformatf("%s: %s (rd beats=%0d wr beats=%0d)",  // 타임아웃 오류 보고
               j.convert2string(), why, p_sequencer.mem_drv.n_rd_beats, p_sequencer.mem_drv.n_wr_beats))  // 메시지에 넣을 값들 (지금까지 읽고 쓴 beat 수)
  endfunction                                       // job_timeout 끝

  // 다시 idle (메모리 검사와 coverage는 scoreboard가 마지막 B 뒤에 이미 함)
  task wait_idle();                                 // 완료 뒤 idle 대기
    bit [31:0] v;                                   // 레지스터 읽기 값
    clocks(5);                                      // 5클럭 대기 (전과 같은 AXI-Lite 접근 시점을 유지)
    do rd(p_sequencer.regmodel.ap_ctrl, v); while (!v[AP_IDLE]);  // 다시 idle
  endtask                                           // wait_idle 끝

  // 레지스터 쓰기 (frontdoor). 응답 코드는 axil_monitor가 검사하므로 status는 보지 않음
  task wr(uvm_reg r, bit [31:0] data);              // 레지스터, 쓸 값
    uvm_status_e status;                            // 접근 결과
    r.write(status, data, .parent(this));           // uvm_reg_map -> adapter -> AXI4-Lite sequencer
  endtask                                           // wr 끝

  // 레지스터 읽기 (frontdoor). 버스에서 읽은 32비트를 돌려줌 (mirror 아님)
  task rd(uvm_reg r, output bit [31:0] data);       // 레지스터, 읽은 값
    uvm_status_e   status;                          // 접근 결과
    uvm_reg_data_t rv;                              // 읽은 값 (64비트, 함수 결과에 비트 선택을 하지 않도록 임시 변수)
    r.read(status, rv, .parent(this));              // uvm_reg_map -> adapter -> AXI4-Lite sequencer
    data = rv[31:0];                                // 하위 32비트
  endtask                                           // rd 끝

  task clocks(int unsigned n);                      // n 클럭 기다리는 도우미
    repeat (n) @(posedge p_sequencer.ctl_vif.clk);  // 클럭 상승 에지 n번 대기
  endtask                                           // clocks 끝
endclass                                            // 클래스 끝
