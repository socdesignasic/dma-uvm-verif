// stream_cfg : agent 모드 + 자극/backpressure 설정값
class stream_cfg extends uvm_object;                    // UVM object 상속
  stream_mode_e    mode      = STREAM_SOURCE;               // agent 모드 (기본 master)
  // master 설정: 리셋 후 첫 beat를 구동하기 전까지 쉬는 사이클
  // (0 = 리셋이 풀리는 첫 사이클부터 valid 구동. AXI-Stream 규격상 허용)
  int unsigned post_reset_idle = 0;                 // 리셋 후 쉬는 사이클 수 (기본 0)
  // slave backpressure 설정
  int unsigned ready_pct = 100;  // 사이클마다 ready=1일 확률(%)
  int unsigned stall_pct = 0;    // 사이클마다 긴 stall을 시작할 확률(%)
  int unsigned max_stall = 0;    // 긴 stall 길이의 상한 (사이클)

  `uvm_object_utils(stream_cfg)                         // factory 등록
  function new(string name = "stream_cfg");             // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝
endclass                                            // 클래스 끝
