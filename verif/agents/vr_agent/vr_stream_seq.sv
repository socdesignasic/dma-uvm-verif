// vr_stream_seq : 랜덤 beat n_items개. 쉬는 간격과 경계값 편향은 선택
class vr_stream_seq extends uvm_sequence #(vr_item);  // vr_item을 만드는 UVM sequence 상속
  `uvm_object_utils(vr_stream_seq)                  // factory 등록
  int unsigned n_items        = 100;                // 만들 beat 수
  int unsigned max_delay      = 0;    // beat 사이 쉬는 사이클 (상한)
  int unsigned zero_delay_pct = 100;  // beat 앞에 쉬는 사이클이 없을 확률(%)
  bit          fix_side       = 0;                  // 1이면 모든 beat의 side를 side_val로 고정
  bit [31:0]   side_val       = 0;                  // 고정할 side 값

  function new(string name = "vr_stream_seq");      // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  // data 경계값 약 8%, side 경계값 약 15% (adder overflow / wrap 자극)
  static const bit [63:0] DATA_CORNER[4] = '{64'h0, 64'hFFFF_FFFF_FFFF_FFFF,  // data 경계값 4개: 0, 전부 1, 각 32비트 최댓값, 각 32비트 최솟값(부호)
                                             64'h7FFF_FFFF_7FFF_FFFF, 64'h8000_0000_8000_0000};  // (위 배열 계속)
  static const bit [31:0] SIDE_CORNER[3] = '{32'h0, 32'h1, 32'hFFFF_FFFF};  // side 경계값 3개: 0, 1, 전부 1

  function void apply_corners(vr_item t);           // item에 경계값을 확률적으로 넣는 함수
    int unsigned pick = $urandom_range(99);         // 0..99 난수
    if (pick < 8) t.data = DATA_CORNER[pick / 2];   // 8% 확률로 data를 경계값 중 하나로
    if (fix_side) t.side = side_val;                // side 고정이면 고정값 사용
    else begin                                      // 고정이 아니면
      pick = $urandom_range(99);                    // 새 난수
      if (pick < 15) t.side = SIDE_CORNER[pick / 5];  // 15% 확률로 side를 경계값 중 하나로
    end                                             // else 끝
  endfunction                                       // apply_corners 끝

  virtual task body();                              // sequence 본문
    repeat (n_items) begin                          // n_items번 반복
      req = vr_item::type_id::create("req");        // 새 item 생성
      start_item(req);                              // sequencer에 item 요청
      if (!req.randomize())                         // data/side 랜덤 생성, 실패하면
        `uvm_fatal("RAND", "vr_item randomize failed")  // 바로 중단
      apply_corners(req);                           // 경계값 편향 적용
      req.delay = (max_delay == 0 || $urandom_range(99) < zero_delay_pct)  // 쉬는 간격이 없거나 zero_delay_pct 확률이면 0
                  ? 0 : $urandom_range(max_delay, 1);  // 아니면 1..max_delay 사이 랜덤
      finish_item(req);                             // driver로 보내고 끝날 때까지 대기
    end                                             // repeat 끝
  endtask                                           // body 끝
endclass                                            // 클래스 끝
