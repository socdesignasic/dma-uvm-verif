// dma_ref_model : job 하나에 대한 DUT의 기대 동작 (참조 모델). dma_predictor가 블록 start 모델의 PRE 진입 에지에 만듦
//   기대 AR / AW 목록 : burst마다 len = min(16, 남은 beat, 4KB 경계까지 beat), INCR, 8바이트
//                      (rdma.v:340-347,400 / wdma.v:359-366,419. 4KB 경계에서만 잘림)
//                      k번째 burst는 계산식(burst_at)으로 바로 구함: 첫 4KB 페이지 안은 16 beat씩, 그 뒤 페이지마다 16 beat x 32개
//   기대 W 데이터     : beat k의 바이트 i = model_byte(src[8k+i], beat k의 VALUE). strobe는 전부 1 (wdma.v:288)
//                      beat k의 VALUE = job.value, 작업 중 VALUE_TO_ADD를 쓰면 add_value(k0, v)로 beat >= k0부터 v
//                      (adder가 R handshake 사이클의 ctrl_constant를 잡음: axis_adder.v:99-109, dma_ip_top.v:302)
//   스냅샷            : PRE 진입 시점 dst 앞뒤 GUARD 바이트 (guard_snap/guard_init). src는 크기에 따라:
//     보통 job (bytes <= LAZY_BYTES) : PRE 진입 시점 src 전체를 복사하고(src_snap) AR/AW 목록과 W 데이터를 미리 만듦.
//                      기대 데이터를 PRE 시점 메모리로 계산하므로 src와 dst가 겹쳐도 맞음
//     큰 job (bytes > LAZY_BYTES)    : 미리 만들지 않음 (PRE 때 O(1)). 목록은 burst_at, W 데이터는 처음 필요할 때 src를 메모리에서
//                      읽어(src_lazy에 남김) 계산. 그 사이 src가 바뀌면 안 되므로 src와 dst가 겹치면 dma_predictor가 PRED_UNSUPPORTED
//   읽는 쪽(scoreboard, predictor)은 n_ar_total/n_aw_total/n_w_total, ar_at/aw_at/w_at, exp_byte/src_byte, guard_addr만 씀
class dma_ref_model extends uvm_object;             // UVM object 상속
  `uvm_object_utils(dma_ref_model)                  // factory 등록
  localparam int unsigned MAX_BURST   = 16;         // DUT burst 최대 beat 수 (NUM_MAX_BURST)
  localparam int unsigned PAGE        = 32'h1000;   // AXI 4KB 경계
  localparam int unsigned PAGE_BEATS  = PAGE / BEAT;  // 4KB 페이지의 beat 수 (512)
  localparam int unsigned PAGE_BURSTS = PAGE_BEATS / MAX_BURST;  // 경계에서 시작하는 페이지의 burst 수 (32)
  // TB가 정한 값 (계획 F4): 1MiB. 기존 테스트의 job은 모두 base test의 1MB 창 안(가장 큰 것 64KB)이라 지금처럼 미리 만들고,
  // 그보다 큰 job(H5의 128MiB 등)은 PRE 때 O(bytes) 작업과 메모리 없이 만듦
  localparam int unsigned LAZY_BYTES  = 32'h0010_0000;

  dma_job    job;                                   // 이 기대값의 job
  axi4_mem   mem;                                   // 메모리 모델 (큰 job이 src를 읽음)
  bit        lazy;                                  // 큰 job (미리 만들지 않음)
  int unsigned n_ar_bursts, n_aw_bursts;            // 기대 AR / AW burst 수
  axi4_item  exp_ar[$];                             // 보통 job: 기대 AR 목록 (순서대로)
  axi4_item  exp_aw[$];                             // 보통 job: 기대 AW 목록 (순서대로)
  bit [63:0] exp_w[$];                              // 보통 job: 기대 W beat 데이터 (순서대로)
  bit [7:0]  src_snap[];                            // 보통 job: PRE 시점 src 바이트
  bit [63:0] src_lazy[$];                           // 큰 job: 처음 필요할 때 읽은 src beat (beat 0부터 차례로)
  bit [7:0]  guard_snap[];                          // PRE 시점 dst 앞뒤 guard 바이트 (guard_addr(g) 순서)
  bit        guard_init[];                          // 그 바이트가 PRE 시점에 쓰인 적 있었는지
  int unsigned val_k[$];                            // 작업 중 VALUE 변경: beat >= val_k[i]부터
  bit [31:0]   val_v[$];                            //                    val_v[i] (쓴 순서대로)
  time       t_abort;                               // dma_predictor: 리셋으로 이 job을 중단한 에지 시각 (중단되지 않았으면 0)

  function new(string name = "dma_ref_model");      // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  // 바이트 하나의 기대값: 원본 + value의 하위 LANE_BW비트 (8비트 wrap)
  static function bit [7:0] model_byte(bit [7:0] s, bit [31:0] value);  // 원본 바이트, 더할 값
    return s + value[LANE_BW-1:0];                  // 기대 바이트
  endfunction                                       // model_byte 끝

  static function int unsigned ceil_burst(int unsigned n);  // n beat를 16 beat씩 나눈 burst 수
    return (n + MAX_BURST - 1) / MAX_BURST;         // 올림
  endfunction                                       // ceil_burst 끝

  // base부터 beats개 중 첫 4KB 페이지에 들어가는 beat 수 (RTL처럼 주소[11:3]로 셈)
  static function int unsigned first_page_beats(bit [31:0] base, int unsigned beats);  // 시작 주소, beat 수
    int unsigned f;                                 // 첫 페이지 beat 수
    f = PAGE_BEATS - (base % PAGE) / BEAT;          // 경계까지 beat 수
    return (f < beats) ? f : beats;                 // 전체보다 많으면 전체
  endfunction                                       // first_page_beats 끝

  // base부터 beats개 beat를 DUT 규칙대로 나눈 burst 수 (계산식, O(1))
  static function int unsigned n_bursts(bit [31:0] base, int unsigned beats);  // 시작 주소, beat 수
    int unsigned f, rest;                           // 첫 페이지 beat 수, 나머지 beat 수
    f    = first_page_beats(base, beats);           // 첫 페이지
    rest = beats - f;                               // 경계에서 시작하는 나머지
    return ceil_burst(f) + (rest / PAGE_BEATS) * PAGE_BURSTS + ceil_burst(rest % PAGE_BEATS);  // 첫 페이지 + 꽉 찬 페이지 + 끝 페이지
  endfunction                                       // n_bursts 끝

  // base부터 beats개 beat의 k번째 burst (계산식, O(1))
  static function axi4_item burst_at(bit is_write, bit [31:0] base, int unsigned beats, int unsigned k);  // 방향, 시작 주소, beat 수, 순번
    int unsigned f, nf, start, n, kk;               // 첫 페이지 beat 수와 burst 수, 이 burst의 첫 beat, beat 수, 첫 페이지 뒤 순번
    axi4_item    b;                                 // 이 burst
    f  = first_page_beats(base, beats);             // 첫 페이지 beat 수
    nf = ceil_burst(f);                             // 첫 페이지 burst 수
    if (k < nf) begin                               // 첫 페이지 안
      start = k * MAX_BURST;                        // 16 beat씩
      n     = f - start;                            // 첫 페이지에 남은 beat
    end else begin                                  // 경계에서 시작하는 페이지들
      kk    = k - nf;                               // 그 안 순번
      start = f + (kk / PAGE_BURSTS) * PAGE_BEATS + (kk % PAGE_BURSTS) * MAX_BURST;  // 페이지 + 페이지 안 위치
      n     = beats - start;                        // 남은 beat (페이지 안 16 beat 단위라 경계를 넘지 않음)
    end                                             // if 끝
    if (n > MAX_BURST) n = MAX_BURST;               // 16 beat 넘으면 16
    b = axi4_item::type_id::create(is_write ? "exp_aw" : "exp_ar");  // 새 burst
    b.is_write = is_write;                          // 방향
    b.addr     = base + start * BEAT;               // 주소
    b.len      = n - 1;                             // 길이 (beat 수 - 1)
    b.size     = 3'd3;                              // 8바이트
    b.burst    = 2'b01;                             // INCR
    return b;                                       // 돌려줌
  endfunction                                       // burst_at 끝

  // job과 PRE 시점 메모리로 기대값과 스냅샷을 만듦 (큰 job은 O(1))
  function void build(dma_job j, axi4_mem m);       // job, 메모리 모델
    int unsigned beats;                             // beat 수
    job   = j;                                      // job 기억
    mem   = m;                                      // 메모리 기억
    beats = j.beats();                              // beat 수
    lazy  = (j.bytes > LAZY_BYTES);                 // 큰 job인지
    n_ar_bursts = n_bursts(j.src, beats);           // 기대 AR 수 (RDMA)
    n_aw_bursts = n_bursts(j.dst, beats);           // 기대 AW 수 (WDMA)
    guard_snap = new[2 * GUARD];                    // guard 스냅샷 (앞 GUARD개, 뒤 GUARD개)
    guard_init = new[2 * GUARD];                    // 같은 크기
    foreach (guard_snap[g]) begin                   // guard 바이트마다
      guard_snap[g] = mem.rd8(guard_addr(g));       // 바이트 값
      guard_init[g] = mem.has(guard_addr(g));       // 쓰인 적 있는지
    end                                             // foreach 끝
    if (lazy) return;                               // 큰 job: 나머지는 필요할 때
    src_snap = new[j.bytes];                        // src 스냅샷 크기
    foreach (src_snap[i]) src_snap[i] = mem.rd8(j.src + i);  // src 바이트 복사
    for (int unsigned k = 0; k < n_ar_bursts; k++) exp_ar.push_back(burst_at(0, j.src, beats, k));  // 기대 AR 목록
    for (int unsigned k = 0; k < n_aw_bursts; k++) exp_aw.push_back(burst_at(1, j.dst, beats, k));  // 기대 AW 목록
    for (int unsigned k = 0; k < beats; k++) exp_w.push_back(make_w(k));  // 기대 W 데이터
  endfunction                                       // build 끝

  // guard 바이트 g의 주소 (0..GUARD-1 = dst 앞, GUARD..2*GUARD-1 = dst+bytes 뒤)
  function bit [31:0] guard_addr(int unsigned g);   // guard 순번
    return (g < GUARD) ? job.dst - GUARD + g : job.dst + job.bytes + (g - GUARD);  // 주소
  endfunction                                       // guard_addr 끝

  // src beat k (보통 job: 스냅샷, 큰 job: 처음 필요할 때 메모리에서 읽어 남김)
  function bit [63:0] src_beat(int unsigned k);     // beat 순번
    bit [63:0] d;                                   // beat 데이터
    if (!lazy) begin                                // 보통 job
      for (int unsigned i = 0; i < BEAT; i++) d[i*8 +: 8] = src_snap[k*BEAT + i];  // 스냅샷
      return d;                                     // 돌려줌
    end                                             // if 끝
    while (src_lazy.size() <= k) begin              // 아직 읽지 않은 beat까지 차례로
      for (int unsigned i = 0; i < BEAT; i++) d[i*8 +: 8] = mem.rd8(job.src + src_lazy.size() * BEAT + i);  // 메모리에서
      src_lazy.push_back(d);                        // 남김
    end                                             // while 끝
    return src_lazy[k];                             // 돌려줌
  endfunction                                       // src_beat 끝

  function bit [7:0] src_byte(int unsigned i);      // src 바이트 i (PRE 시점 값, 큰 job은 처음 읽은 값)
    bit [63:0] s;                                   // beat (함수 결과에 비트 선택을 하지 않도록 임시 변수)
    if (!lazy) return src_snap[i];                  // 보통 job: 스냅샷
    s = src_beat(i / BEAT);                         // 큰 job: beat
    return s[(i % BEAT) * 8 +: 8];                  // 그 바이트
  endfunction                                       // src_byte 끝

  function bit [31:0] value_at(int unsigned k);     // beat k에 더해지는 VALUE_TO_ADD
    bit [31:0] v;                                   // 값
    v = job.value;                                  // PRE 시점 값
    foreach (val_k[i]) if (k >= val_k[i]) v = val_v[i];  // 그 뒤 변경 (쓴 순서대로, 뒤가 이김)
    return v;                                       // 돌려줌
  endfunction                                       // value_at 끝

  function bit [63:0] make_w(int unsigned k);       // beat k의 기대 W 데이터 계산
    bit [63:0] s, w;                                // src beat, 기대 beat
    bit [31:0] v;                                   // 더할 값
    s = src_beat(k);                                // src
    v = value_at(k);                                // 값
    for (int unsigned i = 0; i < BEAT; i++) w[i*8 +: 8] = model_byte(s[i*8 +: 8], v);  // 바이트마다
    return w;                                       // 돌려줌
  endfunction                                       // make_w 끝

  function bit [7:0] exp_byte(int unsigned i);      // dst 바이트 i의 기대값
    return model_byte(src_byte(i), value_at(i / BEAT));  // 원본 + 그 beat의 값
  endfunction                                       // exp_byte 끝

  // 작업 중 VALUE_TO_ADD 변경: beat >= k부터 v (dma_predictor가 W handshake 에지까지의 R 수로 k를 셈)
  function void add_value(int unsigned k, bit [31:0] v);  // 첫 beat, 새 값
    val_k.push_back(k);                             // 기록
    val_v.push_back(v);                             // 기록
    if (!lazy) for (int unsigned i = k; i < exp_w.size(); i++) exp_w[i] = make_w(i);  // 보통 job: 미리 만든 W 데이터 고침
  endfunction                                       // add_value 끝

  function bit overlaps();                          // src와 dst 범위가 겹치는지
    longint unsigned s, d, n;                       // 넘침 없이 비교
    s = job.src; d = job.dst; n = job.bytes;        // 값
    return (s < d + n) && (d < s + n);              // 겹침
  endfunction                                       // overlaps 끝

  function int unsigned n_ar_total(); return n_ar_bursts; endfunction  // 기대 AR 수
  function int unsigned n_aw_total(); return n_aw_bursts; endfunction  // 기대 AW 수 (마지막 B 판단)
  function int unsigned n_w_total();  return job.beats(); endfunction  // 기대 W beat 수
  function axi4_item ar_at(int unsigned k); if (lazy) return burst_at(0, job.src, job.beats(), k); return exp_ar[k]; endfunction  // 기대 AR k
  function axi4_item aw_at(int unsigned k); if (lazy) return burst_at(1, job.dst, job.beats(), k); return exp_aw[k]; endfunction  // 기대 AW k
  function bit [63:0] w_at(int unsigned k); if (lazy) return make_w(k); return exp_w[k]; endfunction  // 기대 W beat k

  function int unsigned ar_beats();                 // 보통 job: 기대 AR 목록의 beat 합
    int unsigned s = 0;                             // 합
    foreach (exp_ar[k]) s += exp_ar[k].beats();     // burst마다 더함
    return s;                                       // 합 돌려줌
  endfunction                                       // ar_beats 끝

  function int unsigned aw_beats();                 // 보통 job: 기대 AW 목록의 beat 합
    int unsigned s = 0;                             // 합
    foreach (exp_aw[k]) s += exp_aw[k].beats();     // burst마다 더함
    return s;                                       // 합 돌려줌
  endfunction                                       // aw_beats 끝

  virtual function string convert2string();         // 로그용 문자열 변환
    if (lazy)                                       // 큰 job
      return $sformatf("lazy (bytes > %0d): exp AR=%0d bursts AW=%0d bursts W=%0d beats, built on demand",  // 크기만
                       LAZY_BYTES, n_ar_bursts, n_aw_bursts, job.beats());  // 값들
    return $sformatf("exp AR=%0d bursts (%0d beats) AW=%0d bursts (%0d beats) W=%0d beats",  // 기대 목록 크기
                     exp_ar.size(), ar_beats(), exp_aw.size(), aw_beats(), exp_w.size());  // 형식 문자열에 넣을 값들
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
