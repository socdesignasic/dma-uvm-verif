// dma_coverage : 작업 단위(크기, 값, 모드, 4KB)와 burst 단위 기능 커버리지
//   cg_job  : scoreboard가 마지막 B까지 검사를 끝낸 job (dma_predictor가 start 순간 mirror로 만든 것)을 job_fifo로 받음.
//             끝나지 않은 job은 샘플링하지 않음
//   cg_burst: m00 monitor가 본 AR/AW burst를 burst_imp로 받음
class dma_coverage extends uvm_component;           // UVM component 상속
  `uvm_component_utils(dma_coverage)                // factory 등록
  uvm_analysis_imp #(axi4_item, dma_coverage) burst_imp;  // burst를 받는 analysis imp (write() 호출됨)
  uvm_tlm_analysis_fifo #(dma_job) job_fifo;        // scoreboard가 검사를 끝낸 job
  int unsigned n_job_samples, n_burst_samples;      // cg_job, cg_burst 샘플 수 (report_phase 로그용)

  // 샘플링할 값
  int unsigned beats, blen;                         // 작업의 beat 수, burst의 beat 수
  bit [7:0]    v8;                                  // 더할 값의 하위 8비트
  bit          upper_set, src_x4k, dst_x4k, is_wr, at_4k_end;  // 상위 비트 사용, 원본/대상 4KB 넘음, 쓰기 여부, 4KB 끝에서 끝남
  done_mode_e  mode;                                // 완료 방식 (polling / 인터럽트)

  covergroup cg_job;                                // 작업 단위 covergroup
    option.per_instance = 1;                        // 인스턴스별로 커버리지 집계
    cp_beats : coverpoint beats { bins one = {1}; bins few = {[2:15]}; bins max_burst = {16};  // 크기 bin: 1 beat, 2~15, 정확히 16
                                  bins multi = {[17:511]}; bins page = {512};  // 17~511 beat, 정확히 512 beat (4KB)
                                  // 상한을 명시: XSim 2022.2가 여기서 `$`를 잘못 계산해
                                  // 모든 작업을 huge로 셌음 (CLAUDE.md의 주의사항 참고)
                                  bins huge = {[513:32'h1FFF_FFFF]}; }  // 512 beat 초과
    cp_value : coverpoint v8    { bins zero = {0}; bins one = {1}; bins max = {255};  // 값 bin: 0, 1, 255
                                  bins other = {[2:254]}; }  // 그 밖의 값
    cp_upper : coverpoint upper_set;   // value_to_add[31:8] != 0 은 무시돼야 함
    cp_mode  : coverpoint mode;                     // 완료 방식 두 가지
    cp_src4k : coverpoint src_x4k;                  // 원본이 4KB 경계를 넘는지
    cp_dst4k : coverpoint dst_x4k;                  // 대상이 4KB 경계를 넘는지
    x_size_mode : cross cp_beats, cp_mode;          // 크기 x 완료 방식 교차
  endgroup                                          // covergroup 끝

  covergroup cg_burst;                              // burst 단위 covergroup
    option.per_instance = 1;                        // 인스턴스별로 커버리지 집계
    cp_dir  : coverpoint is_wr { bins rd = {0}; bins wr = {1}; }  // 방향: 읽기 / 쓰기
    cp_len  : coverpoint blen  { bins one = {1}; bins mid = {[2:15]}; bins full = {16}; }  // burst 길이: 1, 2~15, 16
    cp_4k   : coverpoint at_4k_end { bins split_at_4k = {1}; bins other = {0}; }  // 4KB 경계에서 잘린 burst인지
    x_dir_len : cross cp_dir, cp_len;               // 방향 x 길이 교차
    x_dir_4k  : cross cp_dir, cp_4k;                // 방향 x 4KB 분할 교차
  endgroup                                          // covergroup 끝

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    burst_imp = new("burst_imp", this);             // analysis imp 생성
    job_fifo  = new("job_fifo", this);              // job FIFO 생성
    cg_job    = new();                              // 작업 covergroup 생성
    cg_burst  = new();                              // burst covergroup 생성
  endfunction                                       // 생성자 끝

  virtual task run_phase(uvm_phase phase);          // run 단계: 끝난 job을 받아 샘플링
    dma_job j;                                      // 받은 job
    forever begin                                   // 계속 반복
      job_fifo.get(j);                              // 다음 job (scoreboard가 마지막 B 뒤에 보냄)
      sample_job(j);                                // 샘플링
    end                                             // forever 끝
  endtask                                           // run_phase 끝

  function void sample_job(dma_job j);              // 작업 하나를 샘플링 (run_phase가 호출)
    beats = j.beats(); v8 = j.value[7:0]; upper_set = (j.value[31:8] != 0);  // beat 수, 하위 8비트 값, 상위 비트 사용 여부 계산
    mode = j.mode; src_x4k = j.crosses_4k(j.src); dst_x4k = j.crosses_4k(j.dst);  // 완료 방식, 원본/대상 4KB 넘음 계산
    cg_job.sample();                                // 작업 covergroup 샘플링
    n_job_samples++;                                // 샘플 수 증가
  endfunction                                       // sample_job 끝

  // 4KB 페이지 끝에 딱 맞춰 끝나는 짧은 burst = DUT의 4KB 분할 로직이 동작함
  function void write(axi4_item b);                // monitor가 burst를 보낼 때 호출됨
    bit [31:0] e = b.end_addr();                    // burst 끝 주소
    is_wr = b.is_write; blen = b.beats();           // 방향과 beat 수
    at_4k_end = (e[11:0] == 0) && (b.beats() < 16);  // 4KB 페이지 끝에서 끝나고 16 beat보다 짧으면 1
    cg_burst.sample();                              // burst covergroup 샘플링
    n_burst_samples++;                              // 샘플 수 증가
  endfunction                                       // write 끝

  function void report_phase(uvm_phase phase);      // 결과 보고 단계
    `uvm_info("COV", $sformatf("job=%.1f%% burst=%.1f%% | samples job=%0d burst=%0d",  // 두 covergroup의 커버리지(%)와 샘플 수를 로그로
                               cg_job.get_inst_coverage(), cg_burst.get_inst_coverage(),  // 각 covergroup의 인스턴스 커버리지
                               n_job_samples, n_burst_samples), UVM_LOW)  // 샘플 수 (job 수 = scoreboard의 new path jobs)
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
