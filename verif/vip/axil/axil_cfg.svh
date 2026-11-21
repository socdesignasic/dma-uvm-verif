// axil_cfg : AXI4-Lite master driver의 타이밍 노브 (agent가 config_db "cfg"로 받고, 없으면 기본값으로 만듦)
//   기본값 0 = AW와 W를 같은 사이클에 내고, BREADY/RREADY는 VALID 전에 미리 올림. 이때 driver는 $urandom을 부르지 않고
//   사이클 동작은 노브를 넣기 전과 같음. 단 같은 seed의 기존 테스트 자극(job 크기, 값 등)은 XSim에서 바뀔 수 있음
//   (코드 구조가 바뀌면 같은 seed라도 난수가 달라짐, CLAUDE.md XSim 주의사항). 변경 전후는 판정과 요약 불변량으로 비교
//   driver가 읽는 시점 (접근마다 한 번): max_aw_w_skew는 쓰기를 시작할 때, max_ready_delay는 그 접근의 B/R을 기다리기 시작할 때
//   노브를 켠 채 테스트 중간 리셋은 지원하지 않음: 접근 도중에 master 쪽 신호(AWVALID, WVALID, ARVALID, BREADY, RREADY)가
//   모두 0인 에지가 생기고(AW/W 간격, READY 지연), READY 지연 중에 리셋이 걸리면 driver가 오지 않는 B/R을 계속 기다림
//   (top TB는 dma_reset_vseq가 노브가 0이 아니면 RESET_CFG로 멈춤)
class axil_cfg extends uvm_object;                  // UVM object 상속
  `uvm_object_utils(axil_cfg)                       // factory 등록
  int unsigned max_aw_w_skew   = 0;                 // >0이면 쓰기마다 AW/W 순서를 고름: 같은 사이클 / AW 먼저 d / W 먼저 d (각 1/3), d = 1..이 값 에지
  int unsigned max_ready_delay = 0;                 // >0이면 B/R 응답마다 d = 0..이 값. d > 0이면 READY=0으로 VALID를 본 뒤 d 에지째에 READY를 올림
                                                    // (slave VALID가 READY 없이 d 에지 동안 유지됨). d = 0이면 기본과 같음

  function new(string name = "axil_cfg");           // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function string convert2string();                 // 로그용 설정 요약 문자열
    return $sformatf("aw/w skew<=%0d ready delay<=%0d", max_aw_w_skew, max_ready_delay);  // 노브 두 개
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
