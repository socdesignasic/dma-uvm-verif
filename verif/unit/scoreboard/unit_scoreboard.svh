// unit_scoreboard : 출력 beat를 모델(입력 beat)과 순서대로 비교
`uvm_analysis_imp_decl(_in)                         // 입력용 analysis imp 타입(write_in) 선언
`uvm_analysis_imp_decl(_out)                        // 출력용 analysis imp 타입(write_out) 선언

class unit_scoreboard extends uvm_scoreboard;       // UVM scoreboard 상속
  `uvm_component_utils(unit_scoreboard)             // factory 등록
  uvm_analysis_imp_in  #(stream_item, unit_scoreboard) in_imp;  // 입력 beat를 받는 imp
  uvm_analysis_imp_out #(stream_item, unit_scoreboard) out_imp;  // 출력 beat를 받는 imp
  unit_env_cfg cfg;                                 // env 설정 (모델 종류, lane 폭)

  bit [63:0]   exp_q[$];                            // 기대 출력 큐
  int unsigned n_in, n_out, n_match, n_mismatch;    // 입력 수, 출력 수, 일치 수, 불일치 수

  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
    in_imp  = new("in_imp", this);                  // 입력 imp 생성
    out_imp = new("out_imp", this);                 // 출력 imp 생성
  endfunction                                       // 생성자 끝

  function bit [63:0] model(stream_item t);             // 기준 모델: 입력 beat -> 기대 출력
    bit [63:0] r;                                   // 결과
    bit [63:0] mask = (64'h1 << cfg.lane_bw) - 1;   // lane 하나의 비트 마스크
    if (cfg.model != MODEL_ADD) return t.data;      // 더하기 모델이 아니면 입력 그대로
    for (int l = 0; l < 64 / cfg.lane_bw; l++)      // lane마다
      r |= (((t.data >> (l * cfg.lane_bw)) + t.side) & mask) << (l * cfg.lane_bw);  // lane 값 + side를 lane 폭으로 자르고 제자리에 넣음
    return r;                                       // 결과 반환
  endfunction                                       // model 끝

  function void write_in(stream_item t);                // 입력 beat가 들어올 때 호출됨
    exp_q.push_back(model(t));                      // 기대값을 큐에 넣음
    n_in++;                                         // 입력 수 증가
  endfunction                                       // write_in 끝

  function void write_out(stream_item t);               // 출력 beat가 나올 때 호출됨
    bit [63:0] exp;                                 // 기대값
    n_out++;                                        // 출력 수 증가
    if (exp_q.size() == 0) begin                    // 기대값이 없는데 출력이 나오면
      `uvm_error("SB_UNEXPECTED", $sformatf("beat #%0d: output with no pending input: %s",  // 예상 밖 출력 오류
                                            n_out, t.convert2string()))  // 메시지에 넣을 값들
      return;                                       // 더 비교하지 않음
    end                                             // if 끝
    exp = exp_q.pop_front();                        // 가장 오래된 기대값 꺼냄
    if (t.data !== exp) begin                       // 실제와 다르면
      n_mismatch++;                                 // 불일치 수 증가
      `uvm_error("SB_MISMATCH", $sformatf("beat #%0d: exp=0x%016h act=0x%016h",  // 불일치 오류 보고
                                          n_out, exp, t.data))  // 메시지에 넣을 값들
    end else                                        // 같으면
      n_match++;                                    // 일치 수 증가
  endfunction                                       // write_out 끝

  function void check_phase(uvm_phase phase);       // 검사 단계
    if (n_in == 0)                                  // 입력이 하나도 없었으면
      `uvm_error("SB_NO_TRAFFIC", "no input beats observed")  // 오류 보고
    if (exp_q.size() != 0)                          // 나오지 않은 기대값이 남았으면
      `uvm_error("SB_LEFTOVER", $sformatf("%0d input beats never came out (first exp=0x%016h)",  // 오류 보고
                                          exp_q.size(), exp_q[0]))  // 남은 개수와 첫 기대값
  endfunction                                       // check_phase 끝

  function void report_phase(uvm_phase phase);      // 결과 보고 단계
    `uvm_info("SB_SUMMARY", $sformatf("in=%0d out=%0d match=%0d mismatch=%0d pending=%0d",  // 입력/출력/일치/불일치/남은 수 요약
                                      n_in, n_out, n_match, n_mismatch, exp_q.size()), UVM_LOW)  // 요약에 넣을 값들
  endfunction                                       // report_phase 끝
endclass                                            // 클래스 끝
