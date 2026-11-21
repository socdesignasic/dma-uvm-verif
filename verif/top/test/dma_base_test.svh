// dma_base_test : env를 만들고, 설정값으로 작업을 생성해 각각 dma_job_vseq로 실행 (env.vsqr).
// 파생 테스트는 configure()에서 설정값을 바꾸거나 run_jobs()를 override함.
//   +N_JOBS=<n>   DMA 작업 개수를 덮어씀
class dma_base_test extends uvm_test;               // UVM test 상속
  `uvm_component_utils(dma_base_test)               // factory 등록
  dma_env     env;                                  // env
  dma_env_cfg cfg;                                  // env 설정

  // 작업 생성 설정값 (configure()에서 설정)
  int unsigned n_jobs     = 1;                      // 작업 개수
  int unsigned min_beats  = 1;                      // 작업 크기 하한 (beat)
  int unsigned max_beats  = 64;                     // 작업 크기 상한 (beat)
  int unsigned irq_pct    = 0;      // 인터럽트로 완료하는 작업 비율(%) (나머지는 polling)
  bit          force_4k   = 0;      // 전송이 4KB 페이지에 걸치도록 src/dst 배치
  bit [31:0]   mem_base   = 32'h1000_0000;   // SW/mem_copy_test.c와 같음

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  virtual function void configure();                // 파생 테스트가 설정값을 바꾸는 곳 (기본은 비어 있음)
  endfunction                                       // configure 끝

  function void build_phase(uvm_phase phase);       // build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    cfg = dma_env_cfg::type_id::create("cfg");      // env 설정 생성
    configure();                                    // 파생 테스트의 설정값 적용
    if ($value$plusargs("N_JOBS=%d", n_jobs)) `uvm_info("TEST", "N_JOBS overridden by plusarg", UVM_LOW)  // +N_JOBS가 있으면 작업 개수를 덮어쓰고 로그
    uvm_config_db#(dma_env_cfg)::set(this, "env", "cfg", cfg);  // env 설정을 config_db로 전달
    env = dma_env::type_id::create("env", this);    // env 생성
  endfunction                                       // build_phase 끝

  function void start_of_simulation_phase(uvm_phase phase);  // 시뮬레이션 시작 직전 단계
    `uvm_info("TEST", $sformatf("jobs=%0d beats=[%0d:%0d] irq=%0d%% force_4k=%0d | slave %s",  // 설정 요약 로그
              n_jobs, min_beats, max_beats, irq_pct, force_4k, cfg.slv_cfg.convert2string()),  // 요약에 넣을 값들
              UVM_LOW)                              // 로그 출력 수준
  endfunction                                       // start_of_simulation_phase 끝

  // 위치는 절차적으로 계산함 (XSim 2022.2의 `dist`/범위 풀이를
  // 믿을 수 없음, verif/README.md 참고). 작업마다 겹치지 않는 영역을 써서
  // 앞 작업 결과가 뒤 작업과 섞이지 않음.
  function dma_job make_job(int unsigned idx);      // idx번째 작업 생성
    dma_job j = dma_job::type_id::create("job");    // 작업 객체 생성
    bit [31:0] win = mem_base + idx * 32'h0010_0000;          // 작업마다 1MB 영역
    int unsigned beats = $urandom_range(max_beats, min_beats);  // 크기 상한/하한 사이 랜덤 beat 수
    j.bytes = beats * BEAT;                         // 바이트 수 = beat 수 x 8
    if (force_4k) begin                             // 4KB 경계 걸치기 모드면
      // 4KB 경계보다 1..(beats-1) beat 앞에서 시작해 경계에 걸치게 함
      j.src = win + 32'h1000 - BEAT * $urandom_range((beats > 1) ? beats - 1 : 1, 1);  // 원본: 1MB 영역 안 4KB 경계 직전
      j.dst = win + 32'h8_0000 + 32'h1000 - BEAT * $urandom_range((beats > 1) ? beats - 1 : 1, 1);  // 대상: 영역의 512KB 지점 + 4KB 경계 직전
    end else begin                                  // 일반 모드면
      j.src = win + BEAT * $urandom_range(32'h3_0000 / BEAT, 0);  // 원본: 영역 앞 192KB 안 랜덤 위치 (8바이트 정렬)
      j.dst = win + 32'h8_0000 + BEAT * $urandom_range(32'h3_0000 / BEAT, 0);  // 대상: 영역의 512KB 지점 + 192KB 안 랜덤 위치
    end                                             // if 끝
    case ($urandom_range(9))                        // 더할 값 고르기 (0..9)
      0:       j.value = 0;                         // 10% 확률로 0
      1:       j.value = 32'hFF;                    // 10% 확률로 255
      2:       j.value = 1;                         // 10% 확률로 1
      default: j.value = $urandom;     // 위 24비트는 DUT가 무시해야 함
    endcase                                         // case 끝
    j.mode = ($urandom_range(99) < irq_pct) ? DONE_IRQ : DONE_POLL;  // irq_pct 확률로 인터럽트 완료, 아니면 polling
    return j;                                       // 작업 반환
  endfunction                                       // make_job 끝

  // virtual sequencer(env.vsqr)에서 dma_job_vseq로 작업 하나 실행
  task run_job(dma_job j);                          // 작업 하나 실행 태스크
    dma_job_vseq seq = dma_job_vseq::type_id::create("job_vseq");  // 작업 virtual sequence 생성
    seq.job = j;                                    // sequence에 작업 전달
    seq.start(env.vsqr);                            // virtual sequencer에서 실행 (끝날 때까지 대기)
  endtask                                           // run_job 끝

  virtual task run_jobs();                          // 작업들을 차례로 실행 (파생 테스트가 override 가능)
    for (int unsigned i = 0; i < n_jobs; i++)       // n_jobs번 반복
      run_job(make_job(i));                         // 작업 생성 후 실행
  endtask                                           // run_jobs 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    phase.raise_objection(this);                    // 테스트가 끝나지 않도록 objection 올림
    wait_reset();                                   // 리셋 해제 대기
    run_jobs();                                     // 작업 실행
    env.clocks(20);                                 // 20클럭 여유
    phase.drop_objection(this);                     // objection 내림 (테스트 종료 허용)
  endtask                                           // run_phase 끝

  task wait_reset();                                // 리셋 해제를 기다리는 태스크
    @(posedge env.ctl_vif.rst_n);                   // 리셋 신호 상승 에지 대기
    env.clocks(5);                                  // 5클럭 더 대기
  endtask                                           // wait_reset 끝
endclass                                            // 클래스 끝
