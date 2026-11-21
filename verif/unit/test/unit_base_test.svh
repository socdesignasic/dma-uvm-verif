// unit_base_test : 공통 흐름 (stream_rand_seq 시작, 배출 대기, 타임아웃). 테스트는 configure()를 override
class unit_base_test extends uvm_test;              // UVM test 상속
  `uvm_component_utils(unit_base_test)              // factory 등록
  unit_env     env;                                 // env
  unit_env_cfg cfg;                                 // env 설정
  string       kind;                                // DUT 종류 (TB top이 알려 줌)

  // 자극 설정값 (configure()에서 설정)
  int unsigned n_items        = 200;                // beat 개수
  int unsigned max_delay      = 0;                  // beat 사이 쉬는 사이클 상한
  int unsigned zero_delay_pct = 100;                // 쉬지 않을 확률(%)
  bit          fix_side       = 0;                  // 1이면 side 값 고정

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  // 파생 테스트에서 override: 자극 설정값 + cfg.out_cfg backpressure
  virtual function void configure();                // 기본은 비어 있음
  endfunction                                       // configure 끝

  function void build_phase(uvm_phase phase);       // build 단계
    super.build_phase(phase);                       // 부모 build_phase 호출
    cfg = unit_env_cfg::type_id::create("cfg");     // env 설정 생성
    if (!uvm_config_db#(string)::get(this, "", "dut_kind", kind))  // config_db에서 DUT 종류 가져오기
      `uvm_fatal("NO_KIND", "TB top must set dut_kind")  // 없으면 바로 중단
    cfg.model = (kind == "adder") ? MODEL_ADD : MODEL_PASS;  // adder면 더하기 모델, 아니면 통과 모델
    void'(uvm_config_db#(int unsigned)::get(this, "", "lane_bw", cfg.lane_bw));  // lane 폭이 있으면 가져옴 (adder TB만 설정)
    // 일반 테스트는 리셋 후 몇 사이클 뒤에 시작함. 리셋 직후 첫 사이클
    // 경계 상황은 unit_post_reset_test가 따로 다룸 (BUG-001 참고).
    cfg.in_cfg.post_reset_idle = 3;                 // 입력은 리셋 후 3사이클 쉬고 시작
    configure();                                    // 파생 테스트의 설정값 적용
    if ($value$plusargs("N_ITEMS=%d", n_items)) `uvm_info("TEST", "N_ITEMS overridden by plusarg", UVM_LOW)  // +N_ITEMS가 있으면 beat 개수를 덮어쓰고 로그
    uvm_config_db#(unit_env_cfg)::set(this, "env", "cfg", cfg);  // env 설정을 config_db로 전달
    env = unit_env::type_id::create("env", this);   // env 생성
  endfunction                                       // build_phase 끝

  virtual task run_phase(uvm_phase phase);          // run 단계
    stream_rand_seq seq;                              // 스트림 sequence
    longint unsigned budget_ns;                     // 배출 대기 시간 한도 (ns)
    phase.raise_objection(this);                    // 테스트가 끝나지 않도록 objection 올림

    seq                = stream_rand_seq::type_id::create("seq");  // sequence 생성
    seq.n_items        = n_items;                   // beat 개수 전달
    seq.max_delay      = max_delay;                 // 쉬는 사이클 상한 전달
    seq.zero_delay_pct = zero_delay_pct;            // 쉬지 않을 확률 전달
    seq.fix_side       = fix_side;                  // side 고정 여부 전달
    seq.side_val       = $urandom;                  // 고정할 side 값 (랜덤)
    `uvm_info("TEST", $sformatf(                    // 설정 요약 로그
      "dut=%s items=%0d max_delay=%0d zero_delay=%0d%% | out ready=%0d%% stall=%0d%% max_stall=%0d | fix_side=%0d",  // 형식 문자열
      (kind == "adder") ? $sformatf("adder/%0db", cfg.lane_bw) : kind, n_items, max_delay, zero_delay_pct, cfg.out_cfg.ready_pct,  // DUT 이름, beat 수, 간격, 출력 ready
      cfg.out_cfg.stall_pct, cfg.out_cfg.max_stall, fix_side), UVM_LOW)  // stall 설정, side 고정 여부

    seq.start(env.in_agt.sqr);                      // 입력 sequencer에서 sequence 실행 (모든 beat를 보낼 때까지)

    // 배출 대기: 모든 beat가 나올 때까지 기다림. 넉넉한 시간 제한 있음
    budget_ns = 2000 + 10 * longint'(n_items) * (max_delay + 2 + cfg.out_cfg.max_stall) * 4;  // 시간 한도 계산
    fork                                            // 배출 대기와 시간 제한을 병렬로
      while (env.sb.n_out < n_items) #10ns;         // 출력 beat 수가 입력과 같아질 때까지 10ns마다 확인
      begin                                         // 시간 제한 쪽
        #(budget_ns * 1ns);                         // 한도만큼 대기
        `uvm_error("TIMEOUT", $sformatf("drain timeout: %0d/%0d beats out after %0d ns",  // 시간 초과 오류 보고
                                        env.sb.n_out, n_items, budget_ns))  // 메시지에 넣을 값들
      end                                           // 시간 제한 쪽 끝
    join_any                                        // 둘 중 하나가 끝나면 진행
    disable fork;                                   // 남은 쪽 종료
    #200ns;   // 엉뚱한 beat가 더 나오면 scoreboard에 잡히도록 잠시 기다림
    phase.drop_objection(this);                     // objection 내림 (테스트 종료 허용)
  endtask                                           // run_phase 끝
endclass                                            // 클래스 끝
