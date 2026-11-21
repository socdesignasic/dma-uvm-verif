// dma_job : DMA 실행 한 번 (원본, 대상, 크기, 더할 값, 완료 방식)
//   test가 만들어 sequence에 주는 job과, dma_predictor가 블록 start 모델이 PRE에 들어가는 에지에
//   shadow 레지스터로 만드는 job이 있음. predictor job만 t_start, t_done, exp(기대값, 리셋 중단 시각 포함)를 채움
//   멤버를 늘리지 않음: test가 이 객체를 만든 뒤 바로 $urandom을 쓰므로, XSim에서 클래스 모양이 바뀌면 같은 seed의
//   자극이 바뀜 (predictor 쪽 정보는 predictor가 만드는 dma_ref_model에 둠)
class dma_job extends uvm_object;                   // UVM object 상속
  `uvm_object_utils(dma_job)                        // factory 등록
  bit [31:0]  src, dst, bytes, value;               // 원본 주소, 대상 주소, 바이트 수, 더할 값
  done_mode_e mode;                                 // 완료 방식
  int unsigned id;                                  // 작업 번호
  time          t_start;                            // predictor: 모델이 PRE에 들어간 에지 시각 (아니면 0)
  time          t_done;                             // predictor: 마지막 B 시각 (끝나지 않았으면 0)
  dma_ref_model exp;                                // predictor: 이 job의 기대 burst 목록, W 데이터, 스냅샷, 리셋 중단 시각 (아니면 null)

  function new(string name = "dma_job");            // 생성자
    super.new(name);                                // 부모 생성자 호출
  endfunction                                       // 생성자 끝

  function int unsigned beats(); return bytes / BEAT; endfunction  // beat 수 = 바이트 수 / 8
  function bit crosses_4k(bit [31:0] a); return (a >> 12) != ((a + bytes - 1) >> 12); endfunction  // 주소 a부터 bytes만큼이 4KB 경계를 넘는지

  virtual function string convert2string();         // 로그용 문자열 변환
    return $sformatf("job#%0d src=0x%08h dst=0x%08h bytes=%0d (%0d beats) value=0x%08h mode=%s",  // 작업 번호, 주소, 크기, 값, 모드를 한 줄로
                     id, src, dst, bytes, beats(), value, mode.name());  // 형식 문자열에 넣을 값들
  endfunction                                       // convert2string 끝
endclass                                            // 클래스 끝
