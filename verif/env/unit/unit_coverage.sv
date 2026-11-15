// unit_coverage : beat 값(경계값, carry) + 사이클별 handshake 상태
class unit_coverage extends uvm_component;          // UVM component 상속
  `uvm_component_utils(unit_coverage)               // factory 등록
  uvm_analysis_imp #(vr_item, unit_coverage) in_imp;  // 입력 beat를 받는 analysis imp
  vr_vif in_vif, out_vif;                           // 입력/출력 virtual interface (사이클 샘플용)

  bit [63:0] d;                                     // 샘플할 데이터
  bit [31:0] s;                                     // 샘플할 sideband
  bit        lo_carry, hi_carry;                    // 하위/상위 32비트 덧셈의 carry
  bit [1:0]  in_st, out_st;   // {valid, ready}

  covergroup cg_beat;                               // beat 값 covergroup
    option.per_instance = 1;                        // 인스턴스별로 커버리지 집계
    cp_lo   : coverpoint d[31:0]  { bins zero = {0}; bins max = {32'hFFFF_FFFF};  // 하위 32비트: 0, 최댓값
                                    bins msb  = {32'h8000_0000};  // MSB만 1
                                    bins other = {[1:32'h7FFF_FFFF], [32'h8000_0001:32'hFFFF_FFFE]}; }  // 그 밖의 값
    cp_hi   : coverpoint d[63:32] { bins zero = {0}; bins max = {32'hFFFF_FFFF};  // 상위 32비트: 0, 최댓값
                                    bins msb  = {32'h8000_0000};  // MSB만 1
                                    bins other = {[1:32'h7FFF_FFFF], [32'h8000_0001:32'hFFFF_FFFE]}; }  // 그 밖의 값
    cp_side : coverpoint s        { bins zero = {0}; bins one = {1}; bins max = {32'hFFFF_FFFF};  // sideband: 0, 1, 최댓값
                                    bins other = {[2:32'hFFFF_FFFE]}; }  // 그 밖의 값
    // carry는 write()에서 계산: XSim은 coverpoint 식 안의 폭 변환(cast)을 잘못 계산함
    cp_lo_carry : coverpoint lo_carry { bins no = {0}; bins yes = {1}; }  // 하위 덧셈 carry 없음/있음
    cp_hi_carry : coverpoint hi_carry { bins no = {0}; bins yes = {1}; }  // 상위 덧셈 carry 없음/있음
  endgroup                                          // covergroup 끝

  // 사이클별 handshake 상태: 00 idle, 01 ready만, 10 stall, 11 전송
  covergroup cg_cycle;                              // 사이클 covergroup
    option.per_instance = 1;                        // 인스턴스별로 커버리지 집계
    cp_in      : coverpoint in_st  { bins st[] = {[0:3]}; }  // 입력 포트 상태 4가지
    cp_out     : coverpoint out_st { bins st[] = {[0:3]}; }  // 출력 포트 상태 4가지
    cp_in_seq  : coverpoint in_st  { bins b2b = (2'b11 => 2'b11 => 2'b11);  // 입력: 3사이클 연속 전송
                                     bins stall_release = (2'b10 => 2'b11); }  // 입력: stall 뒤 전송
    cp_out_seq : coverpoint out_st { bins b2b = (2'b11 => 2'b11 => 2'b11);  // 출력: 3사이클 연속 전송
                                     bins stall_release = (2'b10 => 2'b11); }  // 출력: stall 뒤 전송
    // 참고용: 어떤 in/out 조합이 나올 수 있는지는 DUT에 달려 있음
    // (예: adder는 in.ready = !out.valid | out.ready). 그래서 weight 0
    x_io : cross cp_in, cp_out { option.weight = 0; }  // 입력 x 출력 상태 교차 (weight 0: 목표에서 제외)
  endgroup                                          // covergroup 끝

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    in_imp   = new("in_imp", this);                 // analysis imp 생성
    cg_beat  = new();                               // beat covergroup 생성
    cg_cycle = new();                               // 사이클 covergroup 생성
  endfunction                                       // 생성자 끝

  function void write(vr_item t);                   // 입력 beat가 들어올 때 호출됨
    bit [32:0] lo_sum, hi_sum;                      // 33비트 덧셈 결과 (carry 포함)
    d = t.data;                                     // 데이터 저장
    s = t.side;                                     // sideband 저장
    lo_sum   = {1'b0, d[31:0]}  + {1'b0, s};        // 하위 32비트 + side
    hi_sum   = {1'b0, d[63:32]} + {1'b0, s};        // 상위 32비트 + side
    lo_carry = lo_sum[32];                          // 하위 carry
    hi_carry = hi_sum[32];                          // 상위 carry
    cg_beat.sample();                               // beat covergroup 샘플링
  endfunction                                       // write 끝

  virtual task run_phase(uvm_phase phase);          // run 단계 (사이클마다 샘플)
    forever begin                                   // 계속 반복
      @(in_vif.moncb);                              // 매 클럭 에지마다
      if (in_vif.moncb.rst !== 1'b0) continue;      // 리셋 중이면 건너뜀
      in_st  = {in_vif.moncb.valid  === 1'b1, in_vif.moncb.ready  === 1'b1};  // 입력 {valid, ready}
      out_st = {out_vif.moncb.valid === 1'b1, out_vif.moncb.ready === 1'b1};  // 출력 {valid, ready}
      cg_cycle.sample();                            // 사이클 covergroup 샘플링
    end                                             // forever 끝
  endtask                                           // run_phase 끝

  function void report_phase(uvm_phase phase);      // 결과 보고 단계
    `uvm_info("COV", $sformatf("beat=%.1f%% cycle=%.1f%%",  // 두 covergroup의 커버리지(%)를 로그로
                               cg_beat.get_inst_coverage(), cg_cycle.get_inst_coverage()), UVM_LOW)  // 각 covergroup의 인스턴스 커버리지
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
