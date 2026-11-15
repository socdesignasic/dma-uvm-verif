// dma_job : DMA 실행 한 번 (원본, 대상, 크기, 더할 값, 완료 방식)
class dma_job extends uvm_object;                   // UVM object 상속
  `uvm_object_utils(dma_job)                        // factory 등록
  bit [31:0]  src, dst, bytes, value;               // 원본 주소, 대상 주소, 바이트 수, 더할 값
  done_mode_e mode;                                 // 완료 방식
  int unsigned id;                                  // 작업 번호

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
