// axi4_slave_cfg : slave의 채널별 backpressure와 지연 설정값
//   driver가 매 사이클(또는 AW/R beat/B마다) 이 객체를 다시 읽으므로 테스트가 실행 중에 바꿔도 됨 (aw_fixed_wait, w_ready_pct,
//   r_gap_pct, min/max_b_latency 등). 한 번의 대기에 쓰는 값은 한 번만 읽음 (도중에 바뀌어도 음수/랩어라운드 없음).
//   w_ready_pct=0이나 r_gap_pct>=100은 그 채널을 멈춤 (값을 다시 낮추면 이어서 진행)
class axi4_slave_cfg extends uvm_object;              // UVM object 상속
  `uvm_object_utils(axi4_slave_cfg)                   // factory 등록
  int unsigned ar_ready_pct  = 100;  // 사이클마다 ARREADY=1일 확률(%)
  int unsigned aw_ready_pct  = 100;                 // 사이클마다 AWREADY=1일 확률(%)
  int unsigned aw_fixed_wait = 0;    // >0이면 AWVALID 후 이 사이클 수만큼 AWREADY를 0으로 유지 (AWVALID를 본 순간의 값)
  int unsigned w_ready_pct   = 100;                 // 사이클마다 WREADY=1일 확률(%)
  int unsigned r_gap_pct     = 0;    // R beat 앞에 빈 사이클을 넣을 확률(%)
  int unsigned max_r_latency = 0;    // AR 수락 -> 첫 R beat까지의 사이클 (0..max 균등 분포)
  int unsigned max_b_latency = 0;    // 마지막 W -> BVALID까지의 사이클 (min_b_latency..max 균등 분포)
  int unsigned min_b_latency = 0;    // B 지연 하한. $urandom_range(max, min)이라 0이면 난수열이 하한 없을 때와 같음.
                                     // max < min이면 min으로 고정. dma_job_vseq의 시간 한도는 max로 계산하므로 max >= min으로 둘 것
  int unsigned max_burst_len = 16;   // DUT 사양: 최대 16 beat

  // 결함 주입 (checker self-test 전용, 기본 꺼짐). 켜면 driver가 일부러 틀리게 동작하고, 쓸 때마다 노브를 줄임
  int unsigned inj_r_flip      = 0;  // >0이면 다음 R beat 이만큼에서 데이터 비트 하나를 뒤집음
  int unsigned inj_r_addr      = 0;  // >0이면 다음 R beat 이만큼을 같은 burst 안 이웃 8B에서 읽음 (이웃이 초기화돼 있고 값이 다를 때만)
  bit [31:0]   inj_w_shift_end = 0;  // 0이 아니면 끝 주소(포함 안 함)가 이 값인 다음 쓰기 burst를 +8B 밀어 씀 (한 번 쓰면 0)

  function new(string name = "axi4_slave_cfg");       // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function string convert2string();                 // 로그용 설정 요약 문자열
    string s = $sformatf("ready%% ar=%0d aw=%0d w=%0d | r_gap=%0d%% r_lat<=%0d b_lat<=%0d",  // ready 확률과 지연 상한을 한 줄로
                         ar_ready_pct, aw_ready_pct, w_ready_pct, r_gap_pct,  // 형식 문자열에 넣을 확률 값
                         max_r_latency, max_b_latency);  // 형식 문자열에 넣을 지연 값
    if (min_b_latency > 0) s = {s, $sformatf(" b_lat>=%0d", min_b_latency)};  // 하한이 있을 때만 (기본 설정의 로그는 전과 같음)
    return s;                                       // 요약 문자열
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
