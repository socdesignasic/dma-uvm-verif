// dma_size_edge_test : cg_job.x_size_mode 커버리지 채우기: 정확한 경계 크기 x 두 가지 완료 방식.
//   1 beat (최소), 16 beat (burst 하나 가득), 512 beat (4KB 페이지 하나)
// 랜덤 크기로는 이 값들이 거의 나오지 않으므로 여기서 직접 지정함.
class dma_size_edge_test extends dma_base_test;     // 기본 테스트 상속
  `uvm_component_utils(dma_size_edge_test)          // factory 등록
  function new(string name, uvm_component parent); super.new(name, parent); endfunction  // 생성자 (부모 생성자 호출)
  virtual function void configure();                // 설정값 override
    n_jobs = 6;                                     // 작업 6개 (크기 3가지 x 완료 방식 2가지)
  endfunction                                       // configure 끝

  virtual task run_jobs();                          // 작업 실행을 override
    int unsigned sizes[3] = '{1, 16, 512};          // 경계 크기 3가지 (beat)
    for (int unsigned i = 0; i < n_jobs; i++) begin  // 작업마다
      dma_job j = make_job(i);                      // 위치와 값은 기본 방식으로 생성
      j.bytes = sizes[i % 3] * BEAT;                // 크기를 경계값으로 바꿈
      j.mode  = (i < 3) ? DONE_POLL : DONE_IRQ;     // 앞 3개는 polling, 뒤 3개는 인터럽트
      run_job(j);                                   // 실행
    end                                             // for 끝
  endtask                                           // run_jobs 끝
endclass                                            // 클래스 끝
