// dma_error_catcher : checker self-test(dma_checker_test) 전용 보고 catcher. 다른 테스트는 등록하지 않음
//   주입 창(open ~ close)이 열려 있고, UVM_ERROR이고, ID가 그 주입의 예상 ID면:
//     UVM_INFO로 바꾸고, 동작은 UVM_DISPLAY만, 메시지 앞에 "EXPECTED_BY_SELFTEST: "를 붙이고, (주입, ID)별로 셈
//   그 밖의 보고는 그대로 통과 (예상 밖 UVM_ERROR/UVM_FATAL은 ID별로 세기만 함 -> 테스트 FAIL)
//   예상 ID가 한 번도 오지 않았는지는 dma_checker_test가 끝에 판정 (SELFTEST_MISS)
class dma_error_catcher extends uvm_report_catcher;  // report catcher 상속
  `uvm_object_utils(dma_error_catcher)              // factory 등록

  // 예상 (주입, ID) 목록: 연 순서대로, 세 큐의 같은 위치가 한 항목
  string       exp_inj[$];                          // 주입 이름
  string       exp_id[$];                           // 예상 ID
  int unsigned exp_hits[$];                         // 낮춘 수
  string       inj;                                 // 열린 주입 창 이름 (빈 문자열이면 닫힘)
  int          open_idx[string];                    // 열린 창의 예상 ID -> 위 목록 위치
  int unsigned unexp[string];                       // 예상 밖 UVM_ERROR/UVM_FATAL의 ID -> 수

  function new(string name = "dma_error_catcher");  // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  // 주입 창 열기: 이 창에서 낮출 예상 ID (id1은 없으면 빈 문자열)
  function void open(string name, string id0, string id1 = "");  // 주입 이름, 예상 ID
    inj = name;                                     // 창 이름
    open_idx.delete();                              // 열린 창의 예상 ID 초기화
    add_exp(id0);                                   // 첫 예상 ID
    if (id1 != "") add_exp(id1);                    // 두 번째 예상 ID
  endfunction                                       // open 끝

  function void add_exp(string id);                 // 열린 창에 예상 ID 하나 추가
    open_idx[id] = exp_id.size();                   // 목록 위치
    exp_inj.push_back(inj);                         // 주입 이름
    exp_id.push_back(id);                           // ID
    exp_hits.push_back(0);                          // 수
  endfunction                                       // add_exp 끝

  function void close();                            // 주입 창 닫기
    inj = "";                                       // 닫힘
    open_idx.delete();                              // 예상 ID 없음
  endfunction                                       // close 끝

  // 보고마다 불림
  virtual function action_e catch();                // catch 콜백
    string id = get_id();                           // 보고 ID
    if (get_severity() == UVM_ERROR && inj != "" && open_idx.exists(id)) begin  // 열린 창의 예상 오류면
      set_severity(UVM_INFO);                       // 정보로
      set_action(UVM_DISPLAY);                      // 화면 출력만 (오류로 세지 않음)
      set_message({"EXPECTED_BY_SELFTEST: ", get_message()});  // 표시
      exp_hits[open_idx[id]]++;                     // 셈
      return THROW;                                 // 다음 catcher와 서버로 넘김
    end                                             // if 끝
    if (get_severity() == UVM_ERROR || get_severity() == UVM_FATAL) begin  // 예상 밖 오류면
      if (unexp.exists(id)) unexp[id]++;            // ID별로 셈
      else                  unexp[id] = 1;          // 처음
    end                                             // if 끝
    return THROW;                                   // 그대로 통과
  endfunction                                       // catch 끝

  function int unsigned n_unexpected();             // 예상 밖 오류 수 (모든 ID 합)
    int unsigned n = 0;                             // 합
    foreach (unexp[k]) n += unexp[k];               // 더함
    return n;                                       // 합 돌려줌
  endfunction                                       // n_unexpected 끝
endclass                                            // 클래스 끝
