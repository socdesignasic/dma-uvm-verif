// dma_predictor : 관찰한 레지스터 접근과 m00 B 응답으로 DUT 동작을 예측해, 모든 AXI-Lite 읽기값과 interrupt 핀을
//                 비교하고 job을 만듦
//   순서: axil_monitor -> axil_fifo -> (여기서 먼저 처리: 읽기 비교) -> reg_ap -> uvm_reg_predictor (mirror 갱신)
//         analysis port는 구독자를 부르는 순서를 정하지 않으므로, 갱신 전 mirror를 보려면 반드시 이 순서
//   사이클 모델 (cycle_loop): control_s_axi.v의 상태 레지스터(start, done, idle, ready, interrupt, auto_restart,
//         auto_restart_status, GIE, IER, ISR)와 데이터 레지스터(shadow), 블록 start 모델, wdma.v 주 상태 머신을
//         클럭마다 계산. control_s_axi.v 부분은 RTL 식 그대로.
//         에지 E의 입력(AXI-Lite AW/W/AR handshake = vif.moncb 표본, 마지막 m00 B = b_loop)은 에지 E+1에서 반영
//         (B는 다른 monitor가 같은 시각에 보내므로 한 에지 늦게 반영해야 처리 순서가 정해짐).
//         그래서 에지 E에서 모델 값 = "에지 E-1 뒤 값" = DUT가 에지 E에서 보는 값. 허용 구간 없음
//   블록 start 모델 (TB 정의 = HLS ap_ctrl_hs 관례, RTL 식이 아님): start는 int_ap_start(level)이고,
//         "WDMA 모델이 IDLE && int_ap_start=1 && 요청 없음"이면 받아들여 요청(r_ap_start_wdma 자리)을 올림.
//         요청이 있는 IDLE은 다음 에지에 PRE, PRE(ap_ready)에서 요청을 내리고 int_ap_start <= auto_restart.
//         단 수: 요청 1단 + PRE 1단. idle에서 쓴 start는 RTL과 같은 사이클 (쓰기 에지 Ew, Ew+1 요청 = wrapper.v:150-157,
//         Ew+2 PRE = wdma.v:310,325, Ew+3 ap_ready = control_s_axi.v:310).
//         작업 중에 써서 남은 start와 auto_restart(control_s_axi.v:311)는 IDLE 진입 에지 Ei를 쓰기 에지처럼 봐서
//         Ei+1 요청, Ei+2 PRE (이 +2는 TB가 정한 값: idle start와 같은 단 수).
//         RTL은 start를 에지(wrapper.v:138 펄스)로 받아 작업 중 start와 auto_restart를 버림 (가설 H1, H2):
//         그 경우 이 모델이 다음 job을 예측하고 DUT는 하지 않으므로 그 테스트가 실패해야 함
//   job : 모델이 PRE에 들어가는 에지(= RTL이 is_run으로 크기와 주소를 잡는 에지, wdma.v:290-297, rdma.v:272-280)에서
//         그 에지 직전의 shadow 레지스터(control_s_axi.v:423-481 식)로 만들고(mode = GIE && IER[0]),
//         dma_ref_model로 기대값과 메모리 스냅샷을 만든 뒤 job_ap로 보냄 (VALUE_TO_ADD는 그 순간 값)
//   VALUE_TO_ADD: adder가 R handshake 사이클의 값을 잡으므로(axis_adder.v:99-109, dma_ip_top.v:302) 작업 중
//         VALUE를 쓰는 W handshake 에지 E에서 k = 이 job이 E 이하 에지에 받은 R handshake 수를 세어 beat >= k의 기대값을
//         새 값으로 (dma_ref_model::add_value). R handshake는 r_loop가 m00 moncb로 셈 (E와 같은 에지의 R은 옛 값)
//   큰 job: bytes > dma_ref_model::LAZY_BYTES이면 기대값을 미리 만들지 않음. src를 W 비교 때 읽으므로 src와 dst가 겹치면 PRED_UNSUPPORTED
//   완료: 그 job의 B 수가 기대 AW 수(n_aw_total)와 같아지면 끝 (t_done = 마지막 B 시각)
//   리셋: rst_n=0을 본 에지 Er에서, 같은 에지의 B까지 b_loop가 처리한 뒤(NBA 영역) 실행 중인 job을 중단하고
//         같은 job을 job_ap로 다시 보내 scoreboard에 알림 (exp.t_abort = Er). Er 이하 시각의 B는 중단한 job 것으로 셈.
//         리셋이 풀린 첫 에지에 모델, shadow, mirror, 읽기 예측, B 시각을 리셋 값으로
//   읽기 비교: AR handshake 에지에서 32비트 예측을 만들어 두고 (읽기 데이터는 AR 에지 직전 값, control_s_axi.v:233-276),
//         axil_monitor가 R에서 내보낸 읽기 item(관찰값)과 비교.
//         예약 비트 = 상수 0, RW 필드 = RAL mirror, DUT가 바꾸는 필드 = 사이클 모델
//         오류 ID: 리셋 뒤 쓴 적 없고 job 전인 레지스터 -> REG_RESET (32비트 전체)
//                  그 밖에서 예약 비트나 RW 필드 -> REG_BITBASH
//                  ISR[0], AP_CTRL.done -> IRQ / start, idle, ready, interrupt[9], ISR[1] -> REG_STATUS
//   interrupt 핀: 매 에지 예측(int_interrupt)과 비교. 어긋나기 시작한 사이클을 IRQ로 보고 (이어지는 사이클은 세기만)
//   모델이 다루지 않는 경우 -> PRED_UNSUPPORTED (바이트 수 0 / 8의 배수 아님 / RDMA != WDMA, 맵에 없는 주소,
//         strobe가 4'hF가 아닌 쓰기, 같은 에지의 쓰기와 읽기, 테스트가 끝날 때 R 없이 남은 AR = 비교하지 못한 읽기,
//         B 장부가 모델과 맞지 않음, 1MiB 넘는 job의 src/dst 겹침)
class dma_predictor extends uvm_component;          // UVM component 상속
  `uvm_component_utils(dma_predictor)               // factory 등록
  // wdma.v 주 상태 머신의 상태 값 (S_IDLE, S_RUN, S_PRE, S_DONE)
  localparam bit [1:0]  W_IDLE = 2'b00, W_RUN = 2'b01, W_PRE = 2'b10, W_DONE = 2'b11;
  // 읽기 예측에서 DUT가 바꾸는 비트 (나머지는 예약 비트 또는 RW 필드)
  localparam bit [31:0] AP_CTRL_DUT = (32'h1 << AP_START) | (32'h1 << AP_DONE) | (32'h1 << AP_IDLE) |
                                      (32'h1 << AP_READY) | (32'h1 << AP_INTERRUPT);
  localparam bit [31:0] ISR_DUT     = 32'h3;        // ISR[1:0]

  // AR 에지에서 만든 읽기 예측 하나 (R에서 온 읽기 item과 짝지음)
  typedef struct {
    bit [11:0] addr;                                // AR 주소
    bit [31:0] val;                                 // 예측 32비트
    bit [31:0] dut;                                 // 그중 DUT가 바꾸는 비트
    bit        in_reset;                            // 리셋 뒤 쓴 적 없고 job 전인 레지스터 (REG_RESET로 보고)
    time       t;                                   // AR handshake 시각
  } rd_pred_t;

  uvm_tlm_analysis_fifo #(axil_item)    axil_fifo;  // axil_monitor가 본 접근
  uvm_tlm_analysis_fifo #(axi4_wb_item) b_fifo;     // m00 monitor가 본 B 응답
  uvm_analysis_port #(axil_item)        reg_ap;     // 처리한 접근 -> uvm_reg_predictor.bus_in
  uvm_analysis_port #(dma_job)          job_ap;     // PRE 진입 에지에 만든 job, 리셋으로 중단한 job(같은 handle을 다시) -> scoreboard
                                                    // (port를 따로 두지 않음: XSim에서 component/port가 늘면 같은 seed의 자극이 바뀜)
  dma_reg_block regmodel;                           // RAL 모델 (env가 연결)
  axi4_mem      mem;                                // 메모리 모델 (env가 연결, start 시점 스냅샷용)
  axil_vif      vif;                                // 제어 interface (env가 연결, handshake 에지, interrupt 핀, rst_n)
  axi4_vif      mem_vif;                            // m00 interface (env가 연결, R handshake 수)

  dma_job      cur;                                 // 실행 중인 job (없으면 null)
  dma_job      ab;                                  // 마지막으로 리셋에 중단한 job (그 에지 이하 시각의 B를 이 job으로 셈)
  int unsigned n_b_cur;                             // cur에 대해 본 B 수
  int unsigned n_jobs, n_done;                      // 만든 job 수, 끝난 job 수
  int unsigned n_dropped;                           // 이미 대기 중인 start에 합쳐져 따로 실행되지 않는 start 쓰기 수 (level이라 한 번)
  int unsigned n_queued;                            // 작업 중에 남은 start나 auto_restart로 IDLE 진입 직후 받아들인 job 수
  int unsigned n_aborted;                           // 리셋으로 중단한 job 수
  int unsigned n_b_no_job;                          // 실행 중인 job 없이 온 B 수
  int unsigned n_b_aborted;                         // 중단한 job의 리셋 에지 이하 시각에 왔지만 중단 뒤 처리된 B 수
  time         done_t[$];                           // job의 마지막 B 시각 (cycle_loop가 다음 에지에 WDMA 모델에 반영)
  int unsigned n_r_hs;                              // 지금까지 본 m00 R handshake 수 (r_loop)
  time         t_r_last;                            // 마지막 R handshake 에지 시각
  int unsigned n_r_base;                            // cur가 PRE에 들어간 에지까지의 R handshake 수
  int unsigned n_value_chg;                         // 작업 중 VALUE_TO_ADD 쓰기 수
  int unsigned n_lazy;                              // 미리 만들지 않은 큰 job 수

  // ---- 사이클 모델 상태: 에지 E-1 뒤 값 ----
  bit        m_ap_start, m_task_ap_done, m_ap_idle, m_ap_ready;  // control_s_axi.v int_ap_start, int_task_ap_done, int_ap_idle, int_ap_ready
  bit        m_interrupt, m_auto_restart, m_ars, m_gie;  // control_s_axi.v int_interrupt, int_auto_restart, auto_restart_status, int_gie
  bit [1:0]  m_ier, m_isr;                          // control_s_axi.v int_ier, int_isr
  bit [11:0] m_waddr;                               // control_s_axi.v waddr (AWADDR[5:0])
  bit [31:0] m_rdma_bytes, m_rdma_ptr;              // shadow: control_s_axi.v int_rdma_transfer_byte, int_rdma_mem_ptr
  bit [31:0] m_wdma_bytes, m_wdma_ptr;              // shadow: int_wdma_transfer_byte, int_wdma_mem_ptr
  bit [31:0] m_axi00, m_value;                      // shadow: int_axi00_ptr0, int_value_to_add
  bit        m_req;                                 // 블록 start 모델: WDMA로 낸 start 요청 (wrapper.v r_ap_start_wdma 자리)
  bit [1:0]  m_wstate;                              // wdma.v c_state
  bit        m_started;                             // 리셋 뒤 start를 쓴 적 있는지
  bit [15:0] m_written;                             // 레지스터별(주소[5:2]) 리셋 뒤 쓴 적 있는지
  bit        m_isr_read_clr;                        // ISR 읽기가 ISR을 지운 뒤 아직 다시 set되지 않음 (IRQ 메시지 구분용)
  // ---- 에지 E에서 표본한 입력 (에지 E+1에서 반영) ----
  bit        in_valid;                              // 표본한 입력이 있는지
  time       in_t;                                  // 그 에지 시각
  bit        in_aw, in_w, in_ar;                    // AW, W, AR handshake
  bit [11:0] in_awaddr, in_araddr;                  // AW 주소, AR 주소 (DUT처럼 [5:0]만)
  bit [31:0] in_wdata;                              // W 데이터
  bit [3:0]  in_wstrb;                              // W strobe
  // ---- 비교 수 ----
  rd_pred_t    rd_q[$];                             // R을 기다리는 읽기 예측
  int unsigned n_rd, n_rd_ap_ctrl, n_rd_isr, n_rd_bad;  // 비교한 읽기 수 (전체, AP_CTRL, ISR), 다른 읽기 수
  int unsigned n_rd_reset;                          // 그중 리셋 값 검사(REG_RESET)로 비교한 읽기 수
  int unsigned n_jobs_irq;                          // 만든 job 중 IRQ 모드 수
  int unsigned n_rd_isr_done, n_rd_done;            // 예측 ISR[0]=1인 ISR 읽기 수, 예측 done=1인 AP_CTRL 읽기 수
  int unsigned n_irq_cycles, n_irq_bad;             // interrupt를 비교한 사이클 수, 다른 사이클 수
  int unsigned n_irq_fall;                          // 예측 interrupt가 1 -> 0으로 내려간 사이클 수 (그 사이클도 핀과 비교)
  bit          irq_bad;                             // 지난 사이클에 interrupt가 달랐는지
  bit          irq_prev;                            // 지난 사이클의 예측 interrupt
  int unsigned n_unsupported;                       // PRED_UNSUPPORTED 수

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    axil_fifo = new("axil_fifo", this);             // 접근 FIFO 생성
    b_fifo    = new("b_fifo", this);                // B FIFO 생성
    reg_ap    = new("reg_ap", this);                // RAL predictor로 가는 port 생성
    job_ap    = new("job_ap", this);                // job port 생성
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    fork                                            // 입력마다 따로 처리
      axil_loop();                                  // AXI-Lite 접근
      b_loop();                                     // m00 B 응답
      cycle_loop();                                 // 사이클 모델과 interrupt 비교
      r_loop();                                     // m00 R handshake 수
    join                                            // (끝나지 않음)
  endtask                                           // run_phase 끝

  // m00 R handshake를 에지마다 셈 (axil moncb와 같은 클럭이지만 두 clocking block의 표본 갱신 순서가 정해지지 않으므로
  // 따로 세고 시각을 남김. model_step은 한 에지 뒤에 r_upto로 읽음)
  task r_loop();                                    // R handshake 수
    forever begin                                   // 매 에지
      @(mem_vif.moncb);                             // 에지 (값은 에지 직전 표본)
      if (mem_vif.moncb.rvalid === 1'b1 && mem_vif.moncb.rready === 1'b1) begin  // R handshake
        n_r_hs++;                                   // 수 증가
        t_r_last = $time;                           // 시각
      end                                           // if 끝
    end                                             // forever 끝
  endtask                                           // r_loop 끝

  // 에지 t 이하에서 본 R handshake 수 (t = 지금보다 한 에지 앞. r_loop가 지금 에지를 이미 셌으면 하나 뺌)
  function int unsigned r_upto(time t);             // 에지 시각
    return n_r_hs - ((t_r_last > t) ? 1 : 0);       // 에지당 R handshake는 하나뿐
  endfunction                                       // r_upto 끝

  task axil_loop();                                 // AXI-Lite 접근을 관찰 순서대로 처리
    axil_item t;                                    // 받은 접근
    forever begin                                   // 계속 반복
      axil_fifo.get(t);                             // 다음 접근
      if (t.write) observe_write(t);                // 쓰기: 모델이 다루는 쓰기인지 확인
      else         check_read(t);                   // 읽기: AR 에지 예측과 비교 (mirror는 아직 이 접근 전 값)
      reg_ap.write(t);                              // 그다음 mirror 갱신
    end                                             // forever 끝
  endtask                                           // axil_loop 끝

  task b_loop();                                    // m00 B 응답 처리
    axi4_wb_item b;                                 // 받은 B
    forever begin                                   // 계속 반복
      b_fifo.get(b);                                // 다음 B
      observe_b(b);                                 // job 완료 판단
    end                                             // forever 끝
  endtask                                           // b_loop 끝

  // 리셋이 풀린 첫 에지(E1)부터 매 에지 모델을 진행. DUT 리셋(areset <= ~ap_rst_n, dma_ip_top.v:141)은
  // 한 클럭 늦게 풀리므로 E1 뒤 값은 리셋 값. 리셋이 다시 걸리면 실행 중인 job을 중단
  task cycle_loop();                                // 사이클 모델
    forever begin                                   // 리셋마다
      @(vif.moncb iff vif.rst_n === 1'b1);          // 리셋이 풀린 첫 에지
      model_reset();                                // 모델과 mirror를 리셋 값으로
      forever begin                                 // 매 에지
        @(vif.moncb);                               // 다음 에지 (값은 에지 직전 표본)
        if (vif.rst_n !== 1'b1) break;              // 리셋이 다시 걸리면 처음부터
        cycle_step();                               // 한 에지 처리
      end                                           // forever 끝
      uvm_wait_for_nba_region();                    // 이 에지의 B까지 b_loop가 처리한 뒤 (같은 시각의 monitor 처리는 NBA 전에 끝남)
      abort_job();                                  // 실행 중인 job 중단
    end                                             // forever 끝
  endtask                                           // cycle_loop 끝

  function void model_reset();                      // 모델 상태를 리셋 값으로
    m_ap_start = 0; m_task_ap_done = 0; m_ap_idle = 0; m_ap_ready = 0;  // control_s_axi.v 리셋 값
    m_interrupt = 0; m_auto_restart = 0; m_ars = 0; m_gie = 0; m_ier = 0; m_isr = 0;  // (계속)
    m_rdma_bytes = 0; m_rdma_ptr = 0; m_wdma_bytes = 0; m_wdma_ptr = 0; m_axi00 = 0; m_value = 0;  // :426-476 리셋 값
    m_waddr = 0;                                    // RTL에는 리셋 없음 (aw_hs 전에는 쓰이지 않음)
    m_req = 0; m_wstate = W_IDLE;                   // 블록 start 모델, WDMA 리셋 값
    m_started = 0; m_written = 0; m_isr_read_clr = 0;  // 기록 초기화
    in_valid = 0; irq_bad = 0; irq_prev = 0;        // 표본 없음
    rd_q.delete(); done_t.delete();                 // 대기 중인 예측과 B 시각 버림
    regmodel.reset();                               // mirror = 리셋 값 (RW 필드 예측이 mirror를 씀)
  endfunction                                       // model_reset 끝

  // 에지 E 하나: 에지 E-1 입력 반영 -> interrupt 비교 -> 에지 E 입력 표본 -> AR이면 읽기 예측
  function void cycle_step();                       // 매 에지 호출
    bit [11:0] aw_a, ar_a;                          // 표본한 주소 (12비트)
    if (in_valid) model_step();                     // 모델 = 에지 E-1 뒤 값
    check_irq_pin(vif.moncb.interrupt);             // 핀 (에지 직전 값 = int_interrupt, 에지 E-1 뒤)
    aw_a      = vif.moncb.awaddr;                   // AW 주소
    ar_a      = vif.moncb.araddr;                   // AR 주소
    in_t      = $time;                              // 이 에지 시각
    in_aw     = (vif.moncb.awvalid === 1'b1 && vif.moncb.awready === 1'b1);  // AW handshake
    in_w      = (vif.moncb.wvalid  === 1'b1 && vif.moncb.wready  === 1'b1);  // W handshake (DUT가 레지스터를 바꾸는 에지)
    in_ar     = (vif.moncb.arvalid === 1'b1 && vif.moncb.arready === 1'b1);  // AR handshake (DUT가 rdata를 잡는 에지)
    in_awaddr = aw_a & 12'h03F;                     // DUT는 AWADDR[5:0]만 씀
    in_araddr = ar_a & 12'h03F;                     // DUT는 ARADDR[5:0]만 씀
    in_wdata  = vif.moncb.wdata;                    // W 데이터
    in_wstrb  = vif.moncb.wstrb;                    // W strobe
    in_valid  = 1;                                  // 다음 에지에서 반영
    if (in_ar) begin                                // 읽기면
      if (in_w) unsupported($sformatf("AXI-Lite write and read handshake on the same edge (AR 0x%03h)", ar_a));  // mirror 순서가 정해지지 않음
      rd_q.push_back(predict_read(ar_a));           // DUT rdata = 이 에지 직전 값 = 지금 모델 값
    end                                             // if 끝
  endfunction                                       // cycle_step 끝

  // 에지 in_t의 입력으로 상태를 한 에지 진행 (오른쪽은 모두 에지 직전 값, 줄 번호는 RTL)
  function void model_step();                       // 모델 한 에지
    bit        ap_done, ap_ready, ap_idle;          // WDMA 출력 (조합)
    bit        is_done, accept;                     // 마지막 B, 블록 start 모델이 start를 받아들임
    bit        wr_ctrl, wr_start, rd_ctrl, rd_isr;  // AP_CTRL 쓰기, 그중 start=1, AP_CTRL 읽기, ISR 읽기
    bit        ars_done, task_done, task_ready;     // control_s_axi.v auto_restart_done, task_ap_done, task_ap_ready
    bit [1:0]  isr_set;                             // 이 에지에 set되는 ISR 비트
    bit [31:0] wmask;                               // control_s_axi.v:155 wmask
    bit        n_interrupt, n_ap_start, n_task_done, n_ap_idle, n_ap_ready, n_auto, n_ars, n_gie, n_req;  // 다음 값
    bit [1:0]  n_ier, n_isr, n_wstate;              // 다음 값
    is_done = 0;                                  // 마지막 B 없음
    while (done_t.size() > 0 && done_t[0] < in_t) begin  // 지난 에지의 B가 남았으면 (일어나면 안 됨)
      unsupported($sformatf("last B at %0t was not applied on its edge", done_t[0]));  // 보고
      void'(done_t.pop_front());                    // 버림
    end                                             // while 끝
    if (done_t.size() > 0 && done_t[0] == in_t) begin  // 이 에지에 마지막 B가 있었으면
      void'(done_t.pop_front());                    // 꺼냄
      is_done = 1;                                  // wdma.v: is_done = b_hs && is_b_last_hs
    end                                             // if 끝
    ap_done  = (m_wstate == W_DONE);                // wdma.v: ap_done = w_s_done
    ap_ready = (m_wstate == W_PRE);                 // wdma.v: ap_ready = w_s_pre
    ap_idle  = (m_wstate == W_IDLE);                // wdma.v: ap_idle = w_s_idle
    wr_ctrl  = in_w && m_waddr == ADDR_AP_CTRL && in_wstrb[0];  // control_s_axi.v:308, 362
    wr_start = wr_ctrl && in_wdata[AP_START];       // :308
    rd_ctrl  = in_ar && in_araddr == ADDR_AP_CTRL;  // control_s_axi.v:331, 352
    rd_isr   = in_ar && in_araddr == ADDR_ISR;      // control_s_axi.v:406, 418
    wmask    = {{8{in_wstrb[3]}}, {8{in_wstrb[2]}}, {8{in_wstrb[1]}}, {8{in_wstrb[0]}}};  // :155
    isr_set  = {m_ier[1] & ap_ready, m_ier[0] & ap_done};  // control_s_axi.v:404, 416
    ars_done   = m_ars && (ap_idle && !m_ap_idle);  // :284 auto_restart_done
    task_done  = (ap_done && !m_ars) || ars_done;   // :282 task_ap_done
    task_ready = ap_ready && !m_auto_restart;       // :283 task_ap_ready
    n_interrupt  = m_gie && (|m_isr);               // :296
    n_ap_start   = wr_start ? 1'b1 : ap_ready ? m_auto_restart : m_ap_start;  // :308-311
    n_task_done  = task_done ? 1'b1 : rd_ctrl ? 1'b0 : m_task_ap_done;  // :329-332
    n_ap_idle    = ap_idle;                         // :341
    n_ap_ready   = task_ready ? 1'b1 : rd_ctrl ? 1'b0 : m_ap_ready;  // :350-353
    n_auto       = wr_ctrl ? in_wdata[AP_AUTO_RESTART] : m_auto_restart;  // :362-363
    n_ars        = m_auto_restart ? 1'b1 : ap_idle ? 1'b0 : m_ars;  // :372-375 auto_restart_status
    n_gie        = (in_w && m_waddr == ADDR_GIE && in_wstrb[0]) ? in_wdata[0] : m_gie;  // :384-385
    n_ier        = (in_w && m_waddr == ADDR_IER && in_wstrb[0]) ? in_wdata[1:0] : m_ier;  // :394-395
    for (int b = 0; b < 2; b++)                     // ISR 비트마다 (set이 읽기 지움보다 먼저)
      n_isr[b] = isr_set[b] ? 1'b1 : rd_isr ? 1'b0 : m_isr[b];  // :404-407, :416-419
    // 블록 start 모델 (TB 정의): IDLE && int_ap_start && 요청 없음 -> 요청, 요청이 있는 IDLE -> PRE, PRE(ap_ready) -> 요청 내림
    accept       = ap_idle && m_ap_start && !m_req;  // 받아들임
    n_req        = accept ? 1'b1 : ap_ready ? 1'b0 : m_req;  // 요청 (wrapper.v:150-157의 set/clear 자리)
    case (m_wstate)                                // wdma.v 주 상태 머신
      W_IDLE:  n_wstate = m_req ? W_PRE : W_IDLE;   // 요청 (wdma.v:325의 is_run 자리)
      W_PRE:   n_wstate = W_RUN;                    // 한 사이클
      W_RUN:   n_wstate = is_done ? W_DONE : W_RUN;  // 마지막 B
      default: n_wstate = W_IDLE;                   // S_DONE -> S_IDLE
    endcase                                         // case 끝
    if (is_done && m_wstate != W_RUN)               // 실행 중이 아닌데 마지막 B
      unsupported($sformatf("last B at %0t while the WDMA model is not running (state %0d)", in_t, m_wstate));  // 보고
    // 요약용 수
    if (wr_start && (ap_ready ? m_auto_restart : m_ap_start)) n_dropped++;  // 이미 남아 있는 start에 합쳐짐
    if (accept && !m_ap_idle) n_queued++;           // IDLE 진입 직후 받아들임 = 작업 중 남은 start나 auto_restart
    // job: PRE에 들어가는 에지 (shadow는 아직 이 에지 전 값 = RTL이 is_run에서 잡는 값)
    if (m_wstate == W_IDLE && n_wstate == W_PRE) start_job();  // job 생성
    // shadow 레지스터 (control_s_axi.v:423-481, strobe 바이트만)
    if (in_w) begin                                 // W handshake
      case (m_waddr)                                // 쓴 주소
        ADDR_RDMA_TRANSFER_BYTE: m_rdma_bytes = (in_wdata & wmask) | (m_rdma_bytes & ~wmask);  // :428-429
        ADDR_RDMA_MEM_PTR:       m_rdma_ptr   = (in_wdata & wmask) | (m_rdma_ptr   & ~wmask);  // :438-439
        ADDR_WDMA_TRANSFER_BYTE: m_wdma_bytes = (in_wdata & wmask) | (m_wdma_bytes & ~wmask);  // :448-449
        ADDR_WDMA_MEM_PTR:       m_wdma_ptr   = (in_wdata & wmask) | (m_wdma_ptr   & ~wmask);  // :458-459
        ADDR_AXI00_PTR0:         m_axi00      = (in_wdata & wmask) | (m_axi00      & ~wmask);  // :468-469
        ADDR_VALUE_TO_ADD: begin                    // 더할 값 (adder에 직결, 잡지 않음)
          m_value = (in_wdata & wmask) | (m_value & ~wmask);  // :478-479
          if (cur != null) value_change(m_value);   // 작업 중이면 이 에지 뒤 R beat부터 새 값
        end                                         // VALUE 끝
        default: ;                                  // 상태 레지스터는 위에서
      endcase                                       // case 끝
    end                                             // if 끝
    // 기록 (읽기 예측의 ID 구분용)
    if (in_w) m_written[m_waddr[5:2]] = 1;          // 쓴 레지스터
    if (wr_start) m_started = 1;                    // start를 씀
    if (isr_set != 0) m_isr_read_clr = 0;           // ISR이 다시 set됨
    else if (rd_isr && m_isr != 0) m_isr_read_clr = 1;  // ISR 읽기가 ISR을 지움
    // 한꺼번에 갱신 (에지)
    m_interrupt = n_interrupt; m_ap_start = n_ap_start; m_task_ap_done = n_task_done;  // control 레지스터
    m_ap_idle = n_ap_idle; m_ap_ready = n_ap_ready; m_auto_restart = n_auto; m_ars = n_ars;  // (계속)
    m_gie = n_gie; m_ier = n_ier; m_isr = n_isr;    // (계속)
    if (in_aw) m_waddr = in_awaddr;                 // control_s_axi.v:193-194 waddr
    m_req = n_req; m_wstate = n_wstate;             // 블록 start 모델, WDMA
  endfunction                                       // model_step 끝

  // AR 에지의 32비트 예측: 예약 비트 = 0, RW 필드 = mirror, DUT가 바꾸는 필드 = 사이클 모델 (에지 직전 값)
  function rd_pred_t predict_read(bit [11:0] a);    // AR 주소 (12비트)
    rd_pred_t      p;                               // 예측
    uvm_reg_data_t mv;                              // mirror 값 (함수 결과에 비트 선택을 하지 않도록 임시 변수)
    p.addr = a;  p.t = $time;  p.val = 0;  p.dut = 0;  // 기본: 모두 0 (예약 비트)
    case (a)                                        // 레지스터마다
      ADDR_AP_CTRL: begin                           // 0x00
        mv = regmodel.ap_ctrl.auto_restart.get_mirrored_value();  // auto_restart (RW)
        p.val[AP_START]        = m_ap_start;        // control_s_axi.v:239
        p.val[AP_DONE]         = m_task_ap_done;    // :240
        p.val[AP_IDLE]         = m_ap_idle;         // :241
        p.val[AP_READY]        = m_ap_ready;        // :242
        p.val[AP_AUTO_RESTART] = mv[0];             // :243
        p.val[AP_INTERRUPT]    = m_interrupt;       // :244
        p.dut = AP_CTRL_DUT;                        // DUT가 바꾸는 비트
      end                                           // AP_CTRL 끝
      ADDR_GIE: begin                               // 0x04
        mv = regmodel.gie.gie.get_mirrored_value(); // gie (RW)
        p.val[0] = mv[0];                           // [0]
      end                                           // GIE 끝
      ADDR_IER: begin                               // 0x08
        mv = regmodel.ier.ier.get_mirrored_value(); // ier (RW)
        p.val[1:0] = mv[1:0];                       // [1:0]
      end                                           // IER 끝
      ADDR_ISR: begin                               // 0x0C
        p.val[1:0] = m_isr;                         // :253
        p.dut = ISR_DUT;                            // DUT가 바꾸는 비트
      end                                           // ISR 끝
      ADDR_RDMA_TRANSFER_BYTE: begin mv = regmodel.rdma_transfer_byte.value.get_mirrored_value(); p.val = mv[31:0]; end  // 0x10
      ADDR_RDMA_MEM_PTR:       begin mv = regmodel.rdma_mem_ptr.value.get_mirrored_value();       p.val = mv[31:0]; end  // 0x14
      ADDR_WDMA_TRANSFER_BYTE: begin mv = regmodel.wdma_transfer_byte.value.get_mirrored_value(); p.val = mv[31:0]; end  // 0x18
      ADDR_WDMA_MEM_PTR:       begin mv = regmodel.wdma_mem_ptr.value.get_mirrored_value();       p.val = mv[31:0]; end  // 0x1C
      ADDR_AXI00_PTR0:         begin mv = regmodel.axi00_ptr0.value.get_mirrored_value();         p.val = mv[31:0]; end  // 0x20
      ADDR_VALUE_TO_ADD:       begin mv = regmodel.value_to_add.value.get_mirrored_value();       p.val = mv[31:0]; end  // 0x24
      default: unsupported($sformatf("read of unmapped address 0x%03h", a));  // 맵에 없는 주소
    endcase                                         // case 끝
    p.in_reset = !m_written[a[5:2]] && !(m_started && (a == ADDR_AP_CTRL || a == ADDR_ISR));  // 리셋 뒤 그대로인 레지스터
    return p;                                       // 예측 돌려줌
  endfunction                                       // predict_read 끝

  // axil_monitor가 본 읽기를 AR 에지 예측과 비교 (32비트 전체, 다른 비트의 종류마다 ID를 나눔)
  function void check_read(axil_item t);            // 관찰한 읽기
    rd_pred_t  p;                                   // 짝이 되는 예측
    bit [31:0] diff;                                // 다른 비트
    bit [31:0] irq_bits;                            // IRQ로 보고하는 비트 (ISR[0], AP_CTRL.done)
    if (rd_q.size() == 0) begin                     // 예측이 없으면 (AR을 못 봄)
      unsupported({"read with no AR seen by the predictor: ", t.convert2string()});  // 보고
      return;                                       // 끝
    end                                             // if 끝
    p = rd_q.pop_front();                           // 가장 오래된 예측
    if (p.addr != t.addr) begin                     // 주소가 다르면 (짝짓기가 어긋남)
      unsupported($sformatf("read 0x%03h paired with AR 0x%03h", t.addr, p.addr));  // 보고
      return;                                       // 끝
    end                                             // if 끝
    n_rd++;                                         // 비교한 읽기 수
    if (p.in_reset) n_rd_reset++;                   // 리셋 값 검사로 비교한 읽기 수
    if (t.addr == ADDR_AP_CTRL) n_rd_ap_ctrl++;     // AP_CTRL 읽기 수
    if (t.addr == ADDR_ISR)     n_rd_isr++;         // ISR 읽기 수
    if (t.addr == ADDR_AP_CTRL && p.val[AP_DONE])   n_rd_done++;      // done=1을 예측한 AP_CTRL 읽기 수
    if (t.addr == ADDR_ISR && p.val[ISR_AP_DONE])   n_rd_isr_done++;  // ISR[0]=1을 예측한 ISR 읽기 수
    diff = t.data ^ p.val;                          // 다른 비트
    `uvm_info("PRED_RD", $sformatf("0x%02h read 0x%08h predicted 0x%08h (AR @%0t)", t.addr, t.data, p.val, p.t), UVM_HIGH)  // 상세 로그
    if (diff == 0) return;                          // 같으면 끝
    n_rd_bad++;                                     // 다른 읽기 수
    if (p.in_reset) begin                           // 리셋 뒤 그대로인 레지스터면 32비트 전체를 리셋 값 검사로
      `uvm_error("REG_RESET", $sformatf("0x%02h read 0x%08h, reset value 0x%08h (bits 0x%08h differ, AR @%0t)",  // 오류 보고
                                         t.addr, t.data, p.val, diff, p.t))  // 값들
      return;                                       // 끝
    end                                             // if 끝
    if ((diff & ~p.dut) != 0)                       // 예약 비트(상수 0)나 RW 필드(mirror)가 다르면
      `uvm_error("REG_BITBASH", $sformatf("0x%02h read 0x%08h, expected 0x%08h: reserved/RW bits 0x%08h differ (AR @%0t)",  // 오류 보고
                                           t.addr, t.data, p.val, diff & ~p.dut, p.t))  // 값들
    if (t.addr == ADDR_ISR && diff[ISR_AP_DONE])    // ① ISR[0]이 예측과 다르면
      `uvm_error("IRQ", $sformatf("ISR[0] (ap_done) read %0d, predicted %0d (ISR=0x%08h, AR @%0t)",  // 오류 보고
                                   t.data[ISR_AP_DONE], p.val[ISR_AP_DONE], t.data, p.t))  // 값들
    if (t.addr == ADDR_AP_CTRL && diff[AP_DONE])    // ③ AP_CTRL.done이 예측과 다르면
      `uvm_error("IRQ", $sformatf("AP_CTRL.done read %0d, predicted %0d (AP_CTRL=0x%08h, AR @%0t)",  // 오류 보고
                                   t.data[AP_DONE], p.val[AP_DONE], t.data, p.t))  // 값들
    irq_bits = (t.addr == ADDR_ISR) ? (32'h1 << ISR_AP_DONE) : (t.addr == ADDR_AP_CTRL) ? (32'h1 << AP_DONE) : 32'h0;  // IRQ로 본 비트
    if ((diff & p.dut & ~irq_bits) != 0)            // 나머지 DUT가 바꾸는 필드가 다르면
      `uvm_error("REG_STATUS", $sformatf("0x%02h read 0x%08h, predicted 0x%08h: status bits 0x%08h differ (AR @%0t)",  // 오류 보고
                                          t.addr, t.data, p.val, diff & p.dut & ~irq_bits, p.t))  // 값들
  endfunction                                       // check_read 끝

  // interrupt 핀 (에지 직전 값)을 int_interrupt 예측과 비교. 어긋나기 시작한 사이클만 보고
  function void check_irq_pin(logic pin);           // 표본한 핀
    n_irq_cycles++;                                 // 비교한 사이클 수
    if (irq_prev && !m_interrupt) n_irq_fall++;     // 예측이 내려간 사이클 (아래에서 핀과 비교)
    irq_prev = m_interrupt;                         // 다음 사이클용
    if (pin === m_interrupt) begin                  // 같으면
      irq_bad = 0;                                  // 어긋남 끝
      return;                                       // 끝
    end                                             // if 끝
    n_irq_bad++;                                    // 다른 사이클 수
    if (irq_bad) return;                            // 이어지는 사이클은 세기만
    irq_bad = 1;                                    // 어긋나기 시작
    if (m_interrupt)                                // ⑤ 와야 할 때 안 옴
      `uvm_error("IRQ", $sformatf("interrupt=%b, expected 1 (GIE=%0d ISR=%b)", pin, m_gie, m_isr))  // 오류 보고
    else if (m_gie && m_isr_read_clr)               // ② ISR을 읽어 지웠는데 내려가지 않음
      `uvm_error("IRQ", $sformatf("interrupt=%b, still high after the ISR read cleared ISR (GIE=%0d ISR=%b)", pin, m_gie, m_isr))  // 오류 보고
    else                                            // ④ 기대하지 않을 때 1 (GIE=0 포함)
      `uvm_error("IRQ", $sformatf("interrupt=%b, not expected (GIE=%0d ISR=%b)", pin, m_gie, m_isr))  // 오류 보고
  endfunction                                       // check_irq_pin 끝

  // AXI-Lite 쓰기 하나: 모델이 다루는 쓰기인지 확인 (상태 변화와 job 생성은 사이클 모델이 W handshake 에지로 함)
  function void observe_write(axil_item t);         // 관찰한 쓰기
    if (!(t.addr <= ADDR_VALUE_TO_ADD && t.addr[1:0] == 2'b00))  // 맵에 없는 주소면
      unsupported($sformatf("write to unmapped address: %s", t.convert2string()));  // 보고
    if (t.strb != 4'hF)                             // 일부 바이트만 쓰면 (mirror가 바이트 strobe를 따르지 않음)
      unsupported($sformatf("write with strobe 0x%h: %s", t.strb, t.convert2string()));  // 보고
  endfunction                                       // observe_write 끝

  // PRE 진입 에지 직전의 shadow 레지스터로 job을 만들어 보냄 (model_step이 부름)
  function void start_job();                        // job 생성
    dma_job j = dma_job::type_id::create("pred_job");  // 새 job
    j.id    = n_jobs++;                             // job 번호
    j.src   = m_rdma_ptr;                           // 원본 주소 (RDMA mem)
    j.dst   = m_wdma_ptr;                           // 대상 주소 (WDMA mem)
    j.bytes = m_rdma_bytes;                         // 바이트 수 (RDMA)
    j.value = m_value;                              // 더할 값 (이 순간 값)
    j.mode  = (m_gie && m_ier[ISR_AP_DONE]) ? DONE_IRQ : DONE_POLL;  // 인터럽트가 나오는 설정이면 IRQ
    if (j.mode == DONE_IRQ) n_jobs_irq++;           // IRQ 모드 job 수 (요약용)
    j.t_start = in_t;                               // PRE 진입 에지 시각
    j.exp   = dma_ref_model::type_id::create("exp");  // 기대값 객체
    j.exp.build(j, mem);                            // 기대 burst 목록, W 데이터, 스냅샷
    if (j.bytes == 0 || j.bytes % BEAT != 0)        // 0이거나 beat 단위가 아니면
      unsupported({"transfer size must be a non-zero multiple of 8 bytes: ", j.convert2string()});  // 보고
    if (m_wdma_bytes != j.bytes)                    // RDMA와 WDMA 바이트 수가 다르면
      unsupported($sformatf("WDMA_TRANSFER_BYTE=%0d differs from RDMA_TRANSFER_BYTE: %s", m_wdma_bytes, j.convert2string()));  // 보고
    if (cur != null)                                // 앞 job이 끝나지 않았는데 PRE (모델 장부가 어긋남)
      unsupported({"model entered PRE while the previous job is still running: ", cur.convert2string()});  // 보고
    if (j.exp.lazy) begin                           // 미리 만들지 않은 큰 job
      n_lazy++;                                     // 수 증가
      if (j.exp.overlaps())                         // src를 W 비교 때 읽으므로 dst와 겹치면 기대값이 틀림
        unsupported({"job larger than 1 MiB with overlapping src/dst: ", j.convert2string()});  // 보고
    end                                             // if 끝
    n_r_base = r_upto(in_t);                        // 이 에지까지의 R 수 (이 job의 R은 그 뒤부터)
    cur     = j;                                    // 실행 중인 job
    n_b_cur = 0;                                    // B 수 초기화
    `uvm_info("PRED_START", {j.convert2string(), " | ", j.exp.convert2string()}, UVM_MEDIUM)  // 상세 로그
    job_ap.write(j);                                // scoreboard로 보냄
  endfunction                                       // start_job 끝

  // B 하나: 실행 중인 job의 B 수를 세고, 기대 AW 수에 이르면 job 완료 (사이클 모델은 다음 에지에 S_DONE)
  function void observe_b(axi4_wb_item b);          // 관찰한 B
    if (cur == null) begin                          // 실행 중인 job이 없으면
      if (ab != null && b.t <= ab.exp.t_abort) n_b_aborted++;  // 리셋 에지 이하 시각이면 중단한 job 것
      else                                 n_b_no_job++;   // 아니면 job 없이 온 B (요약에서 셈)
      return;                                       // 끝
    end                                             // if 끝
    n_b_cur++;                                      // B 수 증가
    if (n_b_cur == cur.exp.n_aw_total()) begin      // 마지막 B면
      cur.t_done = b.t;                             // 완료 시각
      done_t.push_back(b.t);                        // 사이클 모델에 알림
      n_done++;                                     // 끝난 job 수 증가
      `uvm_info("PRED_DONE", $sformatf("%s done at %0t (B=%0d)", cur.convert2string(), b.t, n_b_cur), UVM_MEDIUM)  // 상세 로그
      cur = null;                                   // 실행 중인 job 없음
    end                                             // if 끝
  endfunction                                       // observe_b 끝

  // 작업 중 VALUE_TO_ADD 쓰기 (model_step이 W handshake 에지 in_t에 부름): k = 이 job이 in_t 이하 에지에 받은 R 수,
  // beat >= k의 기대값을 새 값으로. k >= beat 수면 남은 beat가 없어 영향 없음
  function void value_change(bit [31:0] v);         // 새 값
    int unsigned k;                                 // 새 값이 처음 적용되는 beat
    string       note;                              // 로그 꼬리
    k = r_upto(in_t) - n_r_base;                    // R beat 수
    n_value_chg++;                                  // 수 증가
    if (k >= cur.beats()) note = " (all R beats already taken: no effect)";  // 영향 없음 (?:의 문자열 상수는 폭이 채워지므로 if)
    `uvm_info("PRED_VALUE", $sformatf("%s: VALUE_TO_ADD=0x%08h written at %0t after %0d R beats: beats >= %0d use 0x%02h%s",  // 정보
                                      cur.convert2string(), v, in_t, k, k, v[LANE_BW-1:0], note), UVM_LOW)  // 값들
    cur.exp.add_value(k, v);                        // 기대값 변경
  endfunction                                       // value_change 끝

  // 리셋 (cycle_loop가 rst_n=0을 본 에지에서 부름): 실행 중인 job을 중단하고 scoreboard에 알림
  function void abort_job();                        // job 중단
    if (cur == null) return;                        // 실행 중인 job이 없으면 끝
    cur.exp.t_abort = $time;                        // 리셋을 본 에지
    n_aborted++;                                    // 중단한 job 수 증가
    `uvm_info("PRED_ABORT", $sformatf("%s aborted by reset at %0t (B=%0d/%0d)", cur.convert2string(), $time,  // 정보
                                      n_b_cur, cur.exp.n_aw_total()), UVM_LOW)  // B 수
    job_ap.write(cur);                              // scoreboard로 같은 job을 다시 보냄 (exp.t_abort != 0 = 중단)
    ab  = cur;                                      // 늦게 처리되는 같은 시각 B용
    cur = null;                                     // 실행 중인 job 없음
  endfunction                                       // abort_job 끝

  // 예측 모델이 다루지 않는 상황 (테스트가 지원 범위 밖으로 나감)
  function void unsupported(string why);            // 이유
    n_unsupported++;                                // 수 증가
    `uvm_error("PRED_UNSUPPORTED", why)             // 오류 보고
  endfunction                                       // unsupported 끝

  // 테스트 끝: R 없이 남은 AR (그 읽기는 비교되지 않았음). 모든 AXI-Lite 읽기는 R까지 끝나야 함
  function void check_phase(uvm_phase phase);       // 검사 단계
    if (rd_q.size() != 0)                           // 비교하지 못한 읽기 예측이 남았으면
      unsupported($sformatf("%0d AR(s) without R at end of test, first: 0x%03h (AR @%0t)",  // 보고
                            rd_q.size(), rd_q[0].addr, rd_q[0].t));  // 개수와 첫 AR
  endfunction                                       // check_phase 끝

  function void report_phase(uvm_phase phase);      // 보고 단계
    `uvm_info("PRED", $sformatf("jobs=%0d (irq=%0d) done=%0d running=%0d dropped=%0d | B without job=%0d | reads compared=%0d (reset-value=%0d AP_CTRL=%0d ISR=%0d) mismatched=%0d, AR without R=%0d | predicted set: ISR[0]=%0d reads, AP_CTRL.done=%0d reads | interrupt cycles=%0d falls=%0d mismatched=%0d | unsupported=%0d",  // 요약 형식
                                n_jobs, n_jobs_irq, n_done, (cur != null), n_dropped, n_b_no_job,  // job 수와 B 수
                                n_rd, n_rd_reset, n_rd_ap_ctrl, n_rd_isr, n_rd_bad, rd_q.size(),  // 읽기 비교 수
                                n_rd_isr_done, n_rd_done,  // ISR[0], done이 1로 예측된 읽기 수
                                n_irq_cycles, n_irq_fall, n_irq_bad, n_unsupported), UVM_LOW)  // interrupt 비교 수
    `uvm_info("PRED_MODEL", $sformatf("start model: queued=%0d (started from a start left pending or auto_restart) | reset: aborted=%0d, B at/before abort=%0d | VALUE writes during jobs=%0d | lazy jobs=%0d | m00 R beats=%0d",  // 2단계 모델 요약
                                      n_queued, n_aborted, n_b_aborted, n_value_chg, n_lazy, n_r_hs), UVM_LOW)  // 값들
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
