// dma_scoreboard : 작업마다 메모리 내용과 버스 트래픽을 검사
//   start_job()이 burst 목록을 비우고, check_job()은 ap_done 뒤에 실행
class dma_scoreboard extends uvm_scoreboard;        // UVM scoreboard 상속
  `uvm_component_utils(dma_scoreboard)              // factory 등록
  uvm_analysis_imp #(axi4_burst, dma_scoreboard) burst_imp;  // burst를 받는 analysis imp
  axi4_mem     mem;                                 // 메모리 모델 (env가 연결)
  axi4_burst   bursts[$];        // 현재 작업 중에 본 AR+AW
  int unsigned n_jobs, n_jobs_fail;                 // 검사한 작업 수, 실패한 작업 수
  bit          expect_jobs = 1;  // 레지스터만 보는 테스트는 0으로 둠

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    burst_imp = new("burst_imp", this);             // analysis imp 생성
  endfunction                                       // 생성자 끝

  function void write(axi4_burst b);                // monitor가 burst를 보낼 때 호출됨
    bursts.push_back(b);                            // 현재 작업의 burst 목록에 추가
  endfunction                                       // write 끝

  function void start_job(dma_job j);               // 작업 시작 전 호출
    bursts.delete();                                // burst 목록 비우기
  endfunction                                       // start_job 끝

  static function bit [7:0] model_byte(bit [7:0] s, bit [31:0] value);  // 기준 모델: 바이트 하나의 기대값
    return s + value[LANE_BW-1:0];                  // 원본 + 값의 하위 LANE_BW비트 (8비트 wrap)
  endfunction                                       // model_byte 끝

  // src_snapshot: 시작 전에 저장한 원본 바이트 (DUT가 건드리면 안 됨)
  function void check_job(dma_job j, bit [7:0] src_snapshot[], bit [7:0] guard_val);  // 작업 하나 검사 (ap_done 뒤 호출)
    int unsigned errs, rd_beats, wr_beats;          // 오류 수, 읽기 beat 합, 쓰기 beat 합
    bit [7:0] exp, act;                             // 기대 바이트, 실제 바이트

    // 1. 데이터: 대상의 모든 바이트
    for (int unsigned i = 0; i < j.bytes; i++) begin  // 대상의 모든 바이트에 대해
      exp = model_byte(src_snapshot[i], j.value);   // 기대값 계산
      act = mem.rd8(j.dst + i);                     // 메모리에서 실제값 읽기
      if (!mem.has(j.dst + i) || act !== exp) begin  // 쓰이지 않았거나 값이 다르면
        if (errs < 10)                              // 처음 10개만 보고
          `uvm_error("SB_DATA", $sformatf("%s: byte %0d @0x%08h exp=0x%02h act=0x%02h%s",  // 오류 보고 (바이트 위치, 기대값, 실제값)
                     j.convert2string(), i, j.dst + i, exp, act,  // 메시지에 넣을 값들
                     mem.has(j.dst + i) ? "" : " (never written)"))  // 쓰인 적 없으면 표시 추가
        errs++;                                     // 오류 수 증가
      end                                           // if 끝
    end                                             // for 끝
    // 2. dst 앞뒤 넘침/모자람 없음, 원본은 그대로
    for (int unsigned g = 1; g <= GUARD; g++) begin  // 보호 영역 바이트마다 (1..GUARD)
      if (mem.rd8(j.dst - g) !== guard_val || mem.rd8(j.dst + j.bytes - 1 + g) !== guard_val) begin  // dst 앞 또는 뒤의 보호 바이트가 바뀌었으면
        `uvm_error("SB_OVERRUN", $sformatf("%s: write outside dst (guard byte %0d changed)",  // 넘침 오류 보고
                                            j.convert2string(), g))  // 메시지에 넣을 값
        errs++;                                     // 오류 수 증가
        break;                                      // 하나만 보고하고 멈춤
      end                                           // if 끝
    end                                             // for 끝
    for (int unsigned i = 0; i < j.bytes; i++)      // 원본의 모든 바이트에 대해
      if (mem.rd8(j.src + i) !== src_snapshot[i]) begin  // 원본이 저장해 둔 값과 다르면
        `uvm_error("SB_SRC", $sformatf("%s: source byte %0d was modified", j.convert2string(), i))  // 원본 변경 오류 보고
        errs++;                                     // 오류 수 증가
        break;                                      // 하나만 보고하고 멈춤
      end                                           // if 끝
    // 3. 버스 트래픽: 모든 burst가 자기 범위 안에 있고, beat 합계가 정확히 맞음
    foreach (bursts[k]) begin                       // 이번 작업의 burst마다
      axi4_burst b = bursts[k];                     // burst 꺼냄
      bit [31:0] lo = b.is_write ? j.dst : j.src;   // 쓰기면 dst, 읽기면 src가 허용 범위 시작
      if (b.addr < lo || b.end_addr() > lo + j.bytes) begin  // burst가 [lo, lo+bytes) 밖으로 나가면
        `uvm_error("SB_RANGE", $sformatf("%s: %s outside [0x%08h,0x%08h)",  // 범위 오류 보고
                                          j.convert2string(), b.convert2string(), lo, lo + j.bytes))  // 메시지에 넣을 값들
        errs++;                                     // 오류 수 증가
      end                                           // if 끝
      if (b.is_write) wr_beats += b.beats(); else rd_beats += b.beats();  // 방향별 beat 수 합산
    end                                             // foreach 끝
    if (rd_beats != j.beats() || wr_beats != j.beats()) begin  // 읽기나 쓰기 beat 합이 작업 beat 수와 다르면
      `uvm_error("SB_BEATS", $sformatf("%s: AR beats=%0d AW beats=%0d, expected %0d each",  // beat 수 오류 보고
                                        j.convert2string(), rd_beats, wr_beats, j.beats()))  // 메시지에 넣을 값들
      errs++;                                       // 오류 수 증가
    end                                             // if 끝

    n_jobs++;                                       // 검사한 작업 수 증가
    if (errs) n_jobs_fail++;                        // 오류가 있으면 실패 수 증가
    else `uvm_info("SB_JOB", {"PASS ", j.convert2string(),  // 없으면 PASS 로그
                              $sformatf(" bursts=%0d", bursts.size())}, UVM_LOW)  // burst 개수도 함께 출력
  endfunction                                       // check_job 끝

  function void report_phase(uvm_phase phase);      // 결과 보고 단계
    `uvm_info("SB_SUMMARY", $sformatf("jobs=%0d failed=%0d", n_jobs, n_jobs_fail), UVM_LOW)  // 작업 수와 실패 수 요약 로그
  endfunction                                       // report_phase 끝

  function void check_phase(uvm_phase phase);       // 검사 단계
    if (n_jobs == 0 && expect_jobs)                 // 작업을 기대했는데 하나도 검사 안 했으면
      `uvm_error("SB_NO_JOBS", "no DMA job was checked")  // 오류 보고
  endfunction                                       // check_phase 끝
endclass                                            // 클래스 끝
