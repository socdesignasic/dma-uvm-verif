// dma_scoreboard : 작업마다 메모리 내용과 버스 트래픽을 검사
//   monitor와 predictor가 본 것만 씀 (설계 문서의 순서):
//     1. job_fifo: dma_predictor가 블록 start 모델이 PRE에 들어가는 에지에 shadow 레지스터로 만든 job
//     2. job.exp (dma_ref_model): 기대 AR/AW, 기대 W 데이터(작업 중 VALUE 변경 포함), PRE 시점 src와 dst 앞뒤 GUARD 스냅샷
//        (1MiB 넘는 job은 미리 만들지 않고 accessor가 계산)
//     3. AR/AW가 올 때마다 목록의 다음 항목과 주소, len, size, burst 비교 (SB_AR_LIST, SB_AW_LIST),
//        burst가 src/dst 창 안인지 (SB_RANGE)
//     4. W beat마다 기대 데이터와 strobe 비교 (SB_WDATA, SB_WSTRB). W가 AW보다 먼저 와도 beat 순서대로 짝지음
//     5. 마지막 B (B 수 = 기대 AW 수) 뒤에 dst, 앞뒤 guard, src를 start 시점 스냅샷과 비교
//        (SB_DATA, SB_OVERRUN, SB_SRC), 본 beat 합과 남은 기대 목록 (SB_BEATS).
//        검사를 끝낸 job은 판정과 상관없이 done_ap로 coverage에 보냄 (끝나지 않은 job은 보내지 않음)
//     6. 실행 중인 job 없이 온 AR/AW/W/B (SB_NO_JOB_BUS), 끝나지 않은 job (SB_UNFINISHED: 테스트 끝, 또는 다음 job이 올 때),
//        마지막 B까지 간 job이 하나도 없음 (SB_NO_JOBS, 레지스터 테스트는 expect_jobs = 0)
//     7. 리셋: predictor가 중단한 job(job_fifo로 같은 handle이 다시 옴, exp.t_abort != 0)은 정보로만 남김
//        (SB_JOB ABORTED, n_aborted). 그 뒤 job 없이 온 활동은 6의 SB_NO_JOB_BUS. 처리 순서가 정해지지 않은
//        같은 시각 항목은 시각으로 소속을 정함 (항목 시각 <= 중단 에지 exp.t_abort이면 중단한 job 것).
//        같은 job이 exp.t_abort 없이 다시 오면 SB_DUP_JOB
//        중단을 따로 받는 FIFO를 두지 않음: XSim에서 component(FIFO, port)가 늘면 같은 seed의 테스트 자극이 바뀜
class dma_scoreboard extends uvm_scoreboard;        // UVM scoreboard 상속
  `uvm_component_utils(dma_scoreboard)              // factory 등록
  localparam int unsigned MAX_REPORT = 10;          // job 하나에서 같은 종류 오류를 보고하는 최대 수 (세기는 모두)

  uvm_analysis_imp #(axi4_item, dma_scoreboard) burst_imp;  // burst를 받는 analysis imp
  uvm_tlm_analysis_fifo #(dma_job)      job_fifo;   // predictor가 만든 job (같은 job이 다시 오면 리셋 중단)
  uvm_tlm_analysis_fifo #(axi4_wb_item) w_fifo;     // m00 W beat
  uvm_tlm_analysis_fifo #(axi4_wb_item) b_fifo;     // m00 B 응답
  uvm_analysis_port #(dma_job)          done_ap;    // 마지막 B까지 검사를 끝낸 job -> coverage
  axi4_mem     mem;                                 // 메모리 모델 (env가 연결)
  bit          expect_jobs = 1;  // 레지스터만 보는 테스트는 0으로 둠

  dma_job      cur;                                 // 실행 중인 job (predictor가 보낸 것, 없으면 null)
  dma_job      last;                                // 마지막으로 받은 새 job (같은 handle이 다시 오면 중단 알림)
  dma_job      ab;                                  // 마지막으로 중단된 job (시각이 그 중단 에지 이하인 항목의 주인)
  int unsigned n_aborted;                           // 리셋으로 중단된 job 수
  int unsigned n_after_abort;                       // 중단 뒤 처리됐지만 시각으로 중단된 job 것인 항목 수
  int unsigned ar_idx, aw_idx, w_idx, b_cnt;        // cur에서 본 AR 수, AW 수, W beat 수, B 수
  int unsigned ar_beats, aw_beats;                  // cur에서 본 AR, AW의 beat 합
  int unsigned errs_cur;                            // cur의 오류 수
  int unsigned n_list_err, n_wdata_err, n_wstrb_err;  // cur에서 본 목록 불일치, W 데이터 불일치, strobe 불일치 수 (보고 제한용)
  int unsigned n_started;                           // predictor에서 받은 job 수
  int unsigned n_jobs, n_jobs_fail;                 // 마지막 B까지 검사한 job 수, 그중 실패한 수
  int unsigned n_unfinished;                        // 끝나지 않은 job 수
  int unsigned n_bus_ar, n_bus_aw, n_bus_w, n_bus_b;  // 본 m00 AR, AW, W beat, B 수 (레지스터 테스트에서는 모두 0)
  int unsigned n_idle_bus;                          // 실행 중인 job 없이 온 AR/AW/W/B 수

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    burst_imp = new("burst_imp", this);             // analysis imp 생성
    job_fifo  = new("job_fifo", this);              // job FIFO 생성
    w_fifo    = new("w_fifo", this);                // W FIFO 생성
    b_fifo    = new("b_fifo", this);                // B FIFO 생성
    done_ap   = new("done_ap", this);               // 끝난 job port 생성
  endfunction                                       // 생성자 끝

  function void write(axi4_item b);                // monitor가 burst를 보낼 때 호출됨
    check_burst(b);                                 // 기대 목록과 비교
  endfunction                                       // write 끝

  virtual task run_phase(uvm_phase phase);          // run 단계: FIFO를 받음
    fork                                            // 입력마다 따로
      job_loop();                                   // predictor job (새 job과 리셋 중단)
      w_loop();                                     // W beat
      b_loop();                                     // B 응답
    join                                            // (끝나지 않음)
  endtask                                           // run_phase 끝

  // 7: predictor가 리셋으로 중단한 job. 오류가 아니라 정보 (리셋 뒤 활동은 SB_NO_JOB_BUS가 봄)
  function void abort_job(dma_job j);               // 중단 알림 (리셋을 본 에지의 NBA 영역에서 옴)
    if (cur != j) begin                             // 실행 중인 job이 아니면 (이미 마지막 B까지 검사함)
      `uvm_info("SB_JOB", $sformatf("ABORT ignored, not the running job: %s (reset @%0t)", j.convert2string(), j.exp.t_abort), UVM_LOW)  // 정보
      return;                                       // 끝
    end                                             // if 끝
    n_aborted++;                                    // 수 증가
    `uvm_info("SB_JOB", $sformatf("ABORTED %s by reset @%0t: AR=%0d/%0d AW=%0d/%0d W=%0d/%0d B=%0d/%0d errors=%0d",  // job 판정 로그
                                  j.convert2string(), j.exp.t_abort, ar_idx, cur.exp.n_ar_total(),  // job, AR
                                  aw_idx, cur.exp.n_aw_total(), w_idx, cur.exp.n_w_total(),  // AW, W
                                  b_cnt, cur.exp.n_aw_total(), errs_cur), UVM_LOW)  // B, 오류 수
    ab  = cur;                                      // 같은 시각 항목용
    cur = null;                                     // 실행 중인 job 없음
  endfunction                                       // abort_job 끝

  // 7: 실행 중인 job이 없을 때, 시각 t의 항목이 마지막으로 중단된 job 것인지 (t <= 중단 에지)
  function bit of_aborted(time t);                  // 항목 시각
    if (ab == null || t > ab.exp.t_abort) return 0; // 중단된 job이 없거나 그 뒤 항목
    n_after_abort++;                                // 셈 (요약)
    return 1;                                       // 중단된 job 것
  endfunction                                       // of_aborted 끝

  task job_loop();                                  // predictor job 받기
    dma_job j;                                      // 받은 job
    forever begin                                   // 계속 반복
      job_fifo.get(j);                              // 다음 job (모델이 PRE에 들어간 에지에 옴)
      if (j == last) begin                          // 같은 job이 다시 오면 리셋 중단 알림
        if (j.exp.t_abort == 0)                     // 중단 시각 없이 다시 옴 = predictor 장부 오류 (중단으로 넘기지 않음)
          `uvm_error("SB_DUP_JOB", {"same job received again without a reset abort: ", j.convert2string()})  // 오류 보고
        else abort_job(j);                          // 중단 처리
        continue;                                   // 다음
      end                                           // if 끝
      last = j;                                     // 새 job
      n_started++;                                  // 수 증가
      if (cur != null) unfinished("a new job started before its last B");  // 앞 job이 끝나지 않았으면 오류
      cur = j;                                      // 실행 중인 job
      ar_idx = 0; aw_idx = 0; w_idx = 0; b_cnt = 0;  // 본 수 초기화
      ar_beats = 0; aw_beats = 0; errs_cur = 0;     // beat 합과 오류 수 초기화
      n_list_err = 0; n_wdata_err = 0; n_wstrb_err = 0;  // 보고 제한용 수 초기화
    end                                             // forever 끝
  endtask                                           // job_loop 끝

  task w_loop();                                    // W beat 받기
    axi4_wb_item w;                                 // 받은 beat
    forever begin                                   // 계속 반복
      w_fifo.get(w);                                // 다음 beat
      n_bus_w++;                                    // 수 증가
      if (cur == null) begin                        // 실행 중인 job이 없으면
        if (!of_aborted(w.t)) no_job_bus(w.convert2string());  // 중단된 job 것이 아니면 job 없이 온 beat
      end else check_w(w);                          // 기대 데이터와 비교
    end                                             // forever 끝
  endtask                                           // w_loop 끝

  task b_loop();                                    // B 응답 받기
    axi4_wb_item b;                                 // 받은 B
    forever begin                                   // 계속 반복
      b_fifo.get(b);                                // 다음 B
      n_bus_b++;                                    // 수 증가
      if (cur == null) begin                        // 실행 중인 job이 없으면
        if (!of_aborted(b.t)) no_job_bus(b.convert2string());  // 중단된 job 것이 아니면 job 없이 온 B
      end else begin                                // 실행 중인 job이 있으면
        b_cnt++;                                    // B 수 증가
        if (b_cnt == cur.exp.n_aw_total()) finish_job();  // 마지막 B면 메모리 검사 (dma_predictor와 같은 완료 기준)
      end                                           // else 끝
    end                                             // forever 끝
  endtask                                           // b_loop 끝

  // 3: AR/AW 하나를 기대 목록의 다음 항목, src/dst 창과 비교
  function void check_burst(axi4_item b);           // monitor가 본 burst
    axi4_item  e;                                   // 짝이 되는 기대 burst (목록이 끝났으면 null)
    int unsigned k;                                 // 이 burst의 순번 (방향별)
    bit [31:0] lo;                                  // 창 시작 주소
    string     msg;                                 // 오류 메시지
    if (b.is_write) n_bus_aw++; else n_bus_ar++;    // 본 수 증가
    if (cur == null) begin                          // 실행 중인 job이 없으면
      if (!of_aborted(b.t)) no_job_bus(b.convert2string());  // 중단된 job 것이 아니면 오류
      return;                                       // 끝
    end                                             // if 끝
    if (b.is_write) begin                           // AW면
      k = aw_idx;                                   // 순번
      aw_idx++;                                     // 본 AW 수 증가
      if (k < cur.exp.n_aw_total()) e = cur.exp.aw_at(k);  // 기대 AW
      aw_beats += b.beats();                        // beat 합
    end else begin                                  // AR이면
      k = ar_idx;                                   // 순번
      ar_idx++;                                     // 본 AR 수 증가
      if (k < cur.exp.n_ar_total()) e = cur.exp.ar_at(k);  // 기대 AR
      ar_beats += b.beats();                        // beat 합
    end                                             // if 끝
    if (e == null || b.addr != e.addr || b.len != e.len || b.size != e.size || b.burst != e.burst) begin  // 다르면
      msg = $sformatf("%s: %s #%0d is %s, expected %s", cur.convert2string(), b.is_write ? "AW" : "AR", k,  // 메시지
                      b.convert2string(), (e == null) ? "none (list exhausted)" : e.convert2string());  // 기대값
      if (n_list_err < MAX_REPORT) begin            // 처음 몇 개만 보고
        if (b.is_write) `uvm_error("SB_AW_LIST", msg)  // 쓰기 목록 불일치
        else            `uvm_error("SB_AR_LIST", msg)  // 읽기 목록 불일치
      end                                           // if 끝
      n_list_err++;                                 // 불일치 수 증가
      errs_cur++;                                   // 오류 수 증가
    end                                             // if 끝
    lo = b.is_write ? cur.dst : cur.src;            // 쓰기면 dst, 읽기면 src 창
    if (b.addr < lo || b.end_addr() > lo + cur.bytes) begin  // burst가 [lo, lo+bytes) 밖으로 나가면
      `uvm_error("SB_RANGE", $sformatf("%s: %s outside [0x%08h,0x%08h)",  // 범위 오류 보고
                                        cur.convert2string(), b.convert2string(), lo, lo + cur.bytes))  // 메시지에 넣을 값들
      errs_cur++;                                   // 오류 수 증가
    end                                             // if 끝
  endfunction                                       // check_burst 끝

  // 4: W beat 하나를 기대 데이터와 비교. strobe는 전부 1 (wdma.v:288, dma_ref_model 참고)
  function void check_w(axi4_wb_item w);            // monitor가 본 W beat
    bit [63:0] ew;                                  // 기대 beat (큰 job은 여기서 계산)
    if (w_idx < cur.exp.n_w_total()) ew = cur.exp.w_at(w_idx);  // 기대 beat가 있으면
    if (w_idx < cur.exp.n_w_total() && w.data !== ew) begin  // 기대 beat가 있고 데이터가 다르면
      if (n_wdata_err < MAX_REPORT)                 // 처음 몇 개만 보고
        `uvm_error("SB_WDATA", $sformatf("%s: W beat %0d data=0x%016h, expected 0x%016h (%s)",  // 오류 보고
                                          cur.convert2string(), w_idx, w.data, ew, w.convert2string()))  // 값들
      n_wdata_err++;                                // 불일치 수 증가
      errs_cur++;                                   // 오류 수 증가
    end                                             // if 끝 (기대보다 많은 beat는 마지막 B 뒤 SB_BEATS가 셈)
    if (w.strb !== {BEAT{1'b1}}) begin              // strobe가 전부 1이 아니면
      if (n_wstrb_err < MAX_REPORT)                 // 처음 몇 개만 보고
        `uvm_error("SB_WSTRB", $sformatf("%s: W beat %0d strb=0x%02h, expected 0x%02h",  // 오류 보고
                                          cur.convert2string(), w_idx, w.strb, {BEAT{1'b1}}))  // 값들
      n_wstrb_err++;                                // 불일치 수 증가
      errs_cur++;                                   // 오류 수 증가
    end                                             // if 끝
    w_idx++;                                        // 다음 beat
  endfunction                                       // check_w 끝

  // 5: 마지막 B 뒤 메모리와 beat 합 검사 (메모리는 B 전에 driver write_engine이 이미 씀)
  function void finish_job();                       // cur 검사 끝
    dma_job       j = cur;                          // 검사할 job
    dma_ref_model e = cur.exp;                      // 기대값과 스냅샷
    int unsigned  n_bad;                            // dst 불일치 바이트 수
    bit [7:0]     exp_b, act;                       // 기대 바이트, 실제 바이트
    bit [31:0]    a;                                // 바이트 주소
    // dst: 모든 바이트 = model_byte(PRE 시점 src, 그 beat의 VALUE) (dma_ref_model::exp_byte)
    for (int unsigned i = 0; i < j.bytes; i++) begin  // dst 바이트마다
      a     = j.dst + i;                            // 주소
      exp_b = e.exp_byte(i);                        // 기대값
      act   = mem.rd8(a);                           // 실제값
      if (!mem.has(a) || act !== exp_b) begin       // 쓰이지 않았거나 다르면
        if (n_bad < MAX_REPORT)                     // 처음 몇 개만 보고
          `uvm_error("SB_DATA", $sformatf("%s: after last B, byte %0d @0x%08h exp=0x%02h act=0x%02h%s",  // 오류 보고
                                           j.convert2string(), i, a, exp_b, act, mem.has(a) ? "" : " (never written)"))  // 값들
        n_bad++;                                    // 불일치 수 증가
        errs_cur++;                                 // 오류 수 증가
      end                                           // if 끝
    end                                             // for 끝
    // 앞뒤 guard: PRE 시점과 값, 쓰인 적 있는지가 같아야 함 (처음 하나만 보고)
    for (int unsigned g = 0; g < 2 * GUARD; g++) begin  // guard 바이트마다 (앞 GUARD개, 뒤 GUARD개)
      a = e.guard_addr(g);                          // 주소
      if (mem.has(a) != e.guard_init[g] || mem.rd8(a) !== e.guard_snap[g]) begin  // 바뀌었으면
        `uvm_error("SB_OVERRUN", $sformatf("%s: guard byte @0x%08h changed: 0x%02h -> 0x%02h",  // 넘침 오류 보고
                                            j.convert2string(), a, e.guard_snap[g], mem.rd8(a)))  // 값들
        errs_cur++;                                 // 오류 수 증가
        break;                                      // 하나만 보고
      end                                           // if 끝
    end                                             // for 끝
    // src: dst와 겹치지 않는 바이트는 PRE 시점과 같아야 함 (겹치는 바이트는 위 dst 비교가 봄).
    //      큰 job은 W 비교 때 처음 읽은 값과 비교 (그 전 변경은 W 데이터 비교와 SB_RANGE가 봄, dma_ref_model 참고)
    for (int unsigned i = 0; i < j.bytes; i++) begin  // src 바이트마다
      a = j.src + i;                                // 주소
      if (a >= j.dst && a < j.dst + j.bytes) continue;  // dst 안이면 건너뜀
      if (mem.rd8(a) !== e.src_byte(i)) begin       // 바뀌었으면
        `uvm_error("SB_SRC", $sformatf("%s: source byte %0d @0x%08h changed: 0x%02h -> 0x%02h",  // 원본 변경 오류 보고
                                        j.convert2string(), i, a, e.src_byte(i), mem.rd8(a)))  // 값들
        errs_cur++;                                 // 오류 수 증가
        break;                                      // 하나만 보고
      end                                           // if 끝
    end                                             // for 끝
    // beat 합과 남은 기대 목록
    if (ar_idx != e.n_ar_total() || aw_idx != e.n_aw_total() ||  // burst 수가 다르거나
        ar_beats != j.beats() || aw_beats != j.beats() || w_idx != j.beats()) begin  // beat 합이 다르면
      `uvm_error("SB_BEATS", $sformatf("%s: at last B AR=%0d/%0d bursts (%0d beats) AW=%0d/%0d bursts (%0d beats) W=%0d beats, expected %0d beats each",  // 오류 보고
                                        j.convert2string(), ar_idx, e.n_ar_total(), ar_beats,  // AR
                                        aw_idx, e.n_aw_total(), aw_beats, w_idx, j.beats()))  // AW, W, 기대
      errs_cur++;                                   // 오류 수 증가
    end                                             // if 끝
    n_jobs++;                                       // 검사한 job 수 증가
    if (errs_cur) n_jobs_fail++;                    // 오류가 있으면 실패 수 증가
    `uvm_info("SB_JOB", $sformatf("%s %s AR=%0d AW=%0d W=%0d B=%0d errors=%0d",  // job 판정 로그
                                  errs_cur ? "FAIL" : "PASS", j.convert2string(), ar_idx, aw_idx, w_idx, b_cnt, errs_cur), UVM_LOW)  // 값들
    done_ap.write(j);                               // coverage 샘플링 (끝난 job만)
    cur = null;                                     // 실행 중인 job 없음
  endfunction                                       // finish_job 끝

  // 6: 실행 중인 job 없이 온 m00 활동 (처음 몇 개만 보고)
  function void no_job_bus(string what);            // 본 항목 설명
    n_idle_bus++;                                   // 수 증가
    if (n_idle_bus <= MAX_REPORT)                   // 처음 몇 개만 보고
      `uvm_error("SB_NO_JOB_BUS", {"m00 activity with no running job: ", what})  // 오류 보고
  endfunction                                       // no_job_bus 끝

  // 6: cur가 마지막 B까지 가지 못함 (when = 어느 시점에 알았는지)
  function void unfinished(string when);            // 설명
    n_unfinished++;                                 // 수 증가
    `uvm_error("SB_UNFINISHED", $sformatf("%s: %s (AR %0d/%0d, AW %0d/%0d, W beats %0d/%0d, B %0d/%0d)",  // 오류 보고
                                           cur.convert2string(), when, ar_idx, cur.exp.n_ar_total(),  // job, AR
                                           aw_idx, cur.exp.n_aw_total(), w_idx, cur.beats(),  // AW, W
                                           b_cnt, cur.exp.n_aw_total()))  // B
  endfunction                                       // unfinished 끝

  function void report_phase(uvm_phase phase);      // 결과 보고 단계
    `uvm_info("SB_SUMMARY", $sformatf("jobs=%0d failed=%0d | started=%0d unfinished=%0d | m00 AR=%0d AW=%0d W beats=%0d B=%0d, without job=%0d",  // 요약 형식
                                      n_jobs, n_jobs_fail, n_started, n_unfinished,  // job 수
                                      n_bus_ar, n_bus_aw, n_bus_w, n_bus_b, n_idle_bus), UVM_LOW)  // 버스 활동 수
    `uvm_info("SB_RESET", $sformatf("aborted by reset=%0d | items of an aborted job handled after its abort=%0d",  // 리셋 요약
                                    n_aborted, n_after_abort), UVM_LOW)  // 값들
  endfunction                                       // report_phase 끝

  function void check_phase(uvm_phase phase);       // 검사 단계
    if (n_jobs == 0 && expect_jobs)                 // 마지막 B까지 검사한 job이 없으면
      `uvm_error("SB_NO_JOBS", "no DMA job reached its last B")  // 오류 보고
    if (cur != null) unfinished("still running at end of test");  // 끝나지 않은 job
  endfunction                                       // check_phase 끝
endclass                                            // 클래스 끝
