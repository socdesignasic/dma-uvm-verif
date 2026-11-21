<!-- 생성된 파일입니다. verif/plan.toml을 고친 뒤 python scripts/plan_check.py --write 로 다시 만드세요. 직접 고치지 마세요. -->
# 검증 계획 (계속 갱신하는 문서)

표시: ✅ 완료 · 🚧 진행 중 · ⬜ 계획 · ❌ 버그로 막힘

## P1: 단위 레벨 (`verif/unit`, `unit_env_pkg`, `unit_test_pkg`)
| 기능 | 블록 | 테스트 | 검사 | 커버리지 | 상태 |
|---|---|---|---|---|---|
| 손실 없이 순서대로 전달 | fifo, skid, adder | 모든 unit 테스트 | 순서 비교 scoreboard, 남은 beat/예상 밖 beat | beat 개수 | ✅ |
| adder lane별 덧셈, 32비트 wrap | adder | rand, fixed_value | lane별 덧셈 모델 | `cp_lo/hi_carry` 있음/없음 | ✅ |
| adder 8비트 lane (top 설정) | adder8 | 모든 unit 테스트 | 같은 모델, lane_bw=8 | | ✅ |
| ctrl_constant를 beat마다 샘플링 | adder | rand (side가 beat마다 바뀜) | 모델이 handshake 시점의 side를 사용 | `cp_side` | ✅ |
| value_to_add 고정 (top의 사용 방식) | adder | fixed_value | 같음 | | ✅ |
| backpressure, FIFO 가득 참 | fifo, fifo_d4 | backpressure | scoreboard | `cp_in` stall 상태, `stall_release` | ✅ |
| 빌 때까지 배출, 띄엄띄엄 입력 | 전부 | sparse_input | scoreboard | `cp_out` idle | ✅ |
| 연속(back-to-back) 최대 처리량 | 전부 | smoke | scoreboard | `b2b` 전이 | ✅ |
| 리셋 직후 첫 사이클의 valid | skid, fifo | post_reset | scoreboard | | ❌ BUG-001 |
| 리셋이 충분히 지난 뒤 beat 1개만 보내고 끝남 | skid | single_beat | 1건 비교, 남은 beat/예상 밖 beat, 배출 타임아웃 | | ✅ |
| valid/ready 프로토콜 (유지, X 없음) | 모든 포트 | 전부 | `stream_if`의 SVA (UVM_ERROR) | | ✅ |

## P2: top 레벨 `dma_ip_top` (`verif/top`, `dma_env_pkg`, `dma_seq_pkg`, `dma_test_pkg`)
env: AXI4-Lite master (`axil_agent` + `axil_monitor`) → DUT → AXI4 slave agent + 메모리 모델 (`axi4_slave_pkg`). 레지스터는 RAL(`dma_reg_block`, frontdoor는 `axil_reg_adapter`), 검사는 `dma_predictor`(모든 AXI-Lite 읽기와 interrupt 핀 예측, start 순간에 job 생성) + `dma_scoreboard`(모니터 기반: AR/AW 목록, W beat, 마지막 B 뒤 메모리).
작업마다: `dma_job_vseq`가 `SW/mem_copy_test.c`와 같은 순서로 레지스터를 설정하고, 시작하고, 완료(polling 또는 IRQ)를 기다립니다. 판정은 monitor가 본 것으로 `dma_predictor`와 `dma_scoreboard`가 합니다.

| 기능 | 테스트 | 검사 | 커버리지 | 상태 |
|---|---|---|---|---|
| 레지스터 리셋 값 (10개 전부, 32비트 전체, AP_CTRL idle=1과 ISR 포함) | dma_reg_reset_test | RAL 내장 `uvm_reg_hw_reset_seq`로 10개를 읽고, `dma_predictor`가 읽기마다 32비트 전체를 리셋 값과 비교 (REG_RESET, 10회) | | ✅ |
| 레지스터 R/W (AP_CTRL, ISR을 뺀 모든 RW 레지스터): walking 1/0, 사용 안 하는 비트는 0 | dma_reg_bitbash_test | `dma_reg_bitbash_vseq`: 0 배경 `uvm_reg_bit_bash_seq`(walking-1) + 1 배경 `uvm_reg_single_bit_bash_seq`(walking-0), 예약 비트에도 1을 씀. `dma_predictor`가 읽기마다 32비트 전체 비교 (REG_BITBASH, 1024회) | | ✅ |
| 레지스터 읽기 예측: 모든 AXI-Lite 읽기(32비트 전체)와 interrupt 핀(매 사이클)이 RTL 사이클 모델과 같음 | 레지스터 테스트와 모든 작업 테스트 | `dma_predictor`가 AR 에지에서 예측한 값과 R 관찰값을 비교: 리셋 뒤 그대로인 레지스터 (REG_RESET), 예약 비트와 RW 필드 (REG_BITBASH), ISR[0]/AP_CTRL.done/interrupt 핀 (IRQ), start/idle/ready/interrupt[9]/ISR[1] (REG_STATUS), 모델이 다루지 않는 접근 (PRED_UNSUPPORTED). mirror는 `uvm_reg_predictor`가 `axil_reg_adapter`로 갱신 (ADAPTER: 연결 실수) | | ✅ |
| 바이트마다 dst = src + value_to_add[7:0] | 모든 작업 테스트 | W beat마다 기대 데이터와 strobe (SB_WDATA, SB_WSTRB), 마지막 B 뒤 dst 모든 바이트 비교 (SB_DATA). dst는 ~기대값으로 미리 오염 | `cp_value` 0/1/255/그 외 | ✅ |
| value_to_add[31:8] 무시 | 모든 작업 테스트 | 같음 | `cp_upper` | ✅ |
| 넘침/모자람 없음, 원본 보존 | 모든 작업 테스트 | dst 앞뒤 64B 보호 영역, src 스냅샷 | | ✅ |
| burst는 INCR, 8B size와 정렬, 16 beat 이하 | 전부 | `axi4_slave_monitor` 검사 | `cp_len` 1/2-15/16 | ✅ |
| 4KB 경계 분할 | dma_4kb_cross_test (+ 랜덤) | AXI_4KB 검사, SB_RANGE, 4KB 경계에서 나눈 기대 burst 목록과 AR/AW 비교 (SB_AR_LIST, SB_AW_LIST) | `split_at_4k` rd/wr | ✅ |
| AR, AW의 beat 합계 = bytes/8 | 모든 작업 테스트 | SB_BEATS, burst마다 기대 목록의 주소, len, size, burst 비교 (SB_AR_LIST, SB_AW_LIST) | `cp_beats` 1..8192 | ✅ |
| AXI master 프로토콜 (유지, X) | 전부 | `axi4_if`의 SVA | | ✅ |
| R/W/AR/B backpressure, R 지연 | rand, backpressure, long_job | 위 검사 전부 | | ✅ |
| AWREADY backpressure | dma_aw_backpressure_test | WLAST 위치, 완료 여부 (JOB_TIMEOUT, 마지막 B까지 가지 못한 job은 SB_UNFINISHED) | | ❌ BUG-002 |
| AP_CTRL.done polling으로 완료 (읽으면 지워짐) | 대부분 | done 비트, GIE=0이면 인터럽트는 0 유지 (IRQ), AP_CTRL의 start/idle/ready 예측 (REG_STATUS) | `cp_mode` | ✅ |
| 인터럽트로 완료 (GIE/IER/ISR) | dma_irq_test, rand | ISR[0] 설정, ISR을 읽으면 IRQ 내려감 (IRQ), ISR[1]과 AP_CTRL 상태 비트 예측 (REG_STATUS) | `cp_mode` | ✅ |
| 정확한 경계 크기 (1 beat, 16 = burst 하나 가득, 512 = 4KB 페이지 하나) × polling과 IRQ 완료 | dma_size_edge_test | 바이트 비교, SB_BEATS, IRQ 검사 | `x_size_mode` one/max_burst/page × 두 모드 | ✅ |
| 기본 경로: 32 beat 작업 하나, backpressure 없음 (빠른 sanity) | dma_smoke_test | 바이트 비교, SB_BEATS, 완료 | `cp_beats` multi | ✅ |
| 짧은 작업: 덜 찬 burst, 1 beat 작업 (1..20 beat, 30개) | dma_short_job_test | 바이트 비교, SB_BEATS, burst 검사 | `cp_beats` one/few, `cp_len` 1/2-15 | ✅ |
| 연속 작업, idle로 복귀 | 모든 다중 작업 테스트 | 작업마다 AP_CTRL.idle | | ✅ |
| 실행 중인 job이 없을 때 m00 버스 활동 없음 (레지스터만 쓰는 동안, job 사이) | 레지스터 테스트와 모든 작업 테스트 | `dma_scoreboard`: job 없이 온 AR/AW/W/B (SB_NO_JOB_BUS). 레지스터 테스트에서는 m00 활동 0 | | ✅ |
| 검사기 자체 시험: 결함을 하나씩 일부러 넣으면 그 결함을 잡아야 하는 검사가 오류를 냄 | dma_checker_test | 주입 5종(R 데이터 비트 뒤집기, 같은 src 안 다른 8B 읽기, 마지막 쓰기 burst +8B, 쓰기 전 / 쓴 뒤 레지스터 읽기 관찰값 bit31)마다 예상 ID(SB_WDATA, SB_DATA, SB_OVERRUN, REG_RESET, REG_BITBASH)가 1회 이상. `dma_error_catcher`가 열린 주입 창의 예상 ID만 낮추고, 하나라도 0회면 SELFTEST_MISS. `+SELFTEST_NO_INJECT`면 FAIL해야 함 (음성 대조, 회귀에 없음) | | ✅ |
| transfer_byte = 0 / 8의 배수가 아님 | (테스트 안 함) | SW가 금지함. 0이면 RTL이 멈춤 | | ⬜ 사양 밖 |
| 작업 중 start는 ap_ctrl_hs대로 기다렸다가 지금 작업 뒤에 실행되고, idle에서 쓴 start는 항상 실행됨 | dma_start_busy_test | B·C 실행 여부(JOB_TIMEOUT), AP_CTRL 예측(REG_STATUS), RDMA만 먼저 읽기(SB_AR_LIST), 고아 W(SB_NO_JOB_BUS), idle에서 start를 받으면 나감(a_ap_idle_leave) | | ❌ BUG-005 |
| auto_restart: 끝날 때마다 같은 설정으로 다시 시작하고, 끄면 지금 반복 뒤 멈춤 | dma_auto_restart_test | 반복 실행(JOB_TIMEOUT, 창 안 AR 수), AP_CTRL 예측(REG_STATUS), a_ap_idle_leave | | ❌ BUG-005 |
| 작업 중 레지스터 10개 쓰기: 크기/주소는 지금 작업에 영향 없음, VALUE_TO_ADD는 그 뒤 R로 받는 beat부터 적용(NOTE-002), ISR 쓰기 무시 | dma_busy_reg_write_test | beat별 기대값(predictor가 VALUE 변경 위치 k로 예측, SB_WDATA/SB_DATA), 레지스터 읽기 예측(REG_BITBASH, IRQ) | | ✅ (가설 H3) |
| done 직후 idle 확인 없이 다음 start (다음 작업 레지스터는 작업 중에 씀) | dma_busy_reg_write_test (dma_pipeline_vseq) | 다음 작업 결과(SB_DATA), 완료(JOB_TIMEOUT), AP_CTRL 예측(REG_STATUS) | | ✅ |
| 제자리 복사(dst=src)와 dst<src 겹침 (dst>src 겹침은 사양 밖) | dma_busy_reg_write_test | 결과 메모리(SB_DATA), W 데이터(SB_WDATA), 앞뒤 guard(SB_OVERRUN) | | ✅ |
| IER=ready만 / 둘 다, GIE 0/1: ISR[1], AP_CTRL.ready(COR), interrupt 핀 | dma_irq_ready_test | ISR과 interrupt 핀 예측(IRQ), AP_CTRL.ready(REG_STATUS) | | ✅ |
| ap_ctrl_hs handshake SVA (bind, 모든 top 테스트) | top의 PASS 테스트 전부 (bind라 모든 테스트에 붙음) | start는 ready까지 유지, ready/done 1사이클, idle 배타, idle에서 start를 받으면 나감, start 없이 시작 안 함 | | ✅ |
| 테스트 중간 리셋: 리셋 뒤 버스 조용, 레지스터 리셋 값, interrupt 0, 다음 작업 정상 | dma_reset_test | 리셋 뒤 버스 활동(SB_NO_JOB_BUS), 리셋 값(REG_RESET), interrupt(IRQ), 리셋 중 AXI-Lite VALID(RESET_BUSY), 리셋 설정(RESET_CFG, NO_VIF), 중단 job 처리(SB_DUP_JOB) | | ✅ |
| 데이터 경로에 beat가 남은 채 리셋 | dma_reset_mid_job_test | 리셋 뒤 start 전 버스 활동(SB_NO_JOB_BUS), 다음 작업 데이터(SB_DATA), WLAST(AXI_WLAST) | | ❌ BUG-006 |
| transfer_byte >= 128MiB (사용자 결정: 사양 안) | dma_size_128mib_test | 첫 burst 길이(SB_AR_LIST/SB_AW_LIST), 이른 done(IRQ, REG_STATUS), 멈춤(JOB_TIMEOUT) | | ❌ BUG-007 |
| 앞 작업 뒤 AWREADY 지연 | dma_aw_wait_after_job_test | WLAST 위치(AXI_WLAST), 완료(JOB_TIMEOUT) | | ❌ BUG-003 |
| B 지연 > W burst 간격 (AW/W 지연 없음) | dma_slow_b_test | WLAST 위치(AXI_WLAST), 완료(JOB_TIMEOUT), 끝나지 않은 job(SB_UNFINISHED) | | ❌ BUG-004 |

## 가설 (RTL을 읽고 세운 것, 시뮬레이션으로 확인하기 전)

| ID | 내용 | 근거 | 확인할 테스트 | 상태 |
|---|---|---|---|---|
| H1 | 작업 중에 start를 쓰면 그 start는 실행되지 않고(RDMA만 끝난 구간이면 RDMA만 다음 src를 읽어 그 데이터가 AW 없이 W로 나감), 그 뒤의 start도 리셋 전까지 무시됨 | `HW/dma_ip/dma_wrapper.v:138`, `HW/dma_ip/dma_wrapper.v:143`, `HW/dma_ip/dma_wrapper.v:155`, `HW/dma_ip/dma_ip_control_s_axi.v:308`, `HW/dma_ip/dma_ip_control_s_axi.v:310`, `HW/dma_ip/RDMA/rdma.v:292`, `HW/dma_ip/RDMA/rdma.v:307`, `HW/dma_ip/WDMA/wdma.v:310`, `HW/dma_ip/WDMA/wdma.v:325`, `HW/dma_ip/WDMA/wdma.v:497` | top/dma_start_busy_test | confirmed → BUG-005 |
| H2 | auto_restart를 켜면 한 번만 돌고, ap_start가 1에 묶여 그 뒤의 start가 리셋 전까지 무시됨 (결과는 H1과 같고 내부 상태는 다름) | `HW/dma_ip/dma_ip_control_s_axi.v:311`, `HW/dma_ip/dma_ip_control_s_axi.v:284`, `HW/dma_ip/dma_ip_control_s_axi.v:363`, `HW/dma_ip/dma_wrapper.v:134`, `HW/dma_ip/dma_wrapper.v:138` | top/dma_auto_restart_test | confirmed → BUG-005 |
| H3 | 작업 중 VALUE_TO_ADD를 바꾸면 그 뒤에 R로 받는 beat부터 새 값이 더해짐 (size/ptr과 달리 start에서 잡지 않음) | `HW/dma_ip/dma_ip_top.v:302`, `HW/dma_ip/axis_adder.v:109`, `HW/dma_ip/RDMA/rdma.v:276` | top/dma_busy_reg_write_test | confirmed → NOTE-002 |
| H4 | 작업 도중 리셋하면 리셋이 없는 adder에 남은 beat(BUG-001로 하나 중복)가 start 없이 AW 없는 W로 나가고, 그 뒤 모든 작업의 dst가 그만큼 밀림 (done은 정상) | `HW/dma_ip/axis_adder.v:38`, `HW/dma_ip/axis_adder.v:99`, `HW/dma_ip/axis_adder.v:123`, `HW/dma_ip/dma_ip_top.v:301`, `HW/dma_ip/dma_ip_top.v:338`, `HW/peri_ip/skid_buffer.v:69`, `HW/dma_ip/WDMA/wdma.v:497` | top/dma_reset_mid_job_test | confirmed → BUG-006 |
| H5 | RDMA/WDMA beat 카운터가 24비트([31-NUM_SAMPLE_IN_AXI_DATA:0])라 transfer_byte >= 2^27(128MiB)이면 beat 수가 (bytes>>3) mod 2^24로 잘림 (일부만 복사하고 done, 나머지 0이면 AR/AW 없이 멈춤) | `HW/dma_ip/RDMA/rdma.v:206`, `HW/dma_ip/RDMA/rdma.v:332`, `HW/dma_ip/RDMA/rdma.v:348`, `HW/dma_ip/RDMA/rdma.v:401`, `HW/dma_ip/WDMA/wdma.v:213`, `HW/dma_ip/WDMA/wdma.v:350`, `HW/dma_ip/WDMA/wdma.v:420` | top/dma_size_128mib_test | confirmed → BUG-007 |
| H6 | burst 끝에서 is_aw_req_pre가 pop 전 상태를 봐서 W FSM이 RUN에 남고, AW FIFO가 빈 채 이전 AWLEN으로 셈 (BUG-002가 첫 작업과 그 뒤에 다르게 나타남) | `HW/dma_ip/WDMA/wdma.v:465`, `HW/dma_ip/WDMA/wdma.v:474`, `HW/dma_ip/WDMA/wdma.v:486`, `HW/dma_ip/WDMA/wdma.v:502`, `HW/dma_ip/WDMA/wdma.v:506`, `HW/dma_ip/WDMA/wdma.v:537`, `HW/peri_ip/sync_fifo.v:99` | top/dma_aw_wait_after_job_test | confirmed → BUG-003 |
| H7 | B 응답이 W burst보다 느리면 W->B FIFO(깊이 4)가 찬 채 burst가 끝나 B 항목이 버려지고, AWREADY가 빨라도 WLAST 오류와 멈춤 | `HW/dma_ip/WDMA/wdma.v:465`, `HW/dma_ip/WDMA/wdma.v:537`, `HW/dma_ip/WDMA/wdma.v:568`, `HW/peri_ip/sync_fifo.v:114` | top/dma_slow_b_test | confirmed → BUG-004 |

## 버그와 waiver (설명은 `verif/BUGS.md`)

| ID | 종류 | 상태 | 내용 | known_fail | waiver |
|---|---|---|---|---|---|
| BUG-001 | bug | wont_fix | 리셋 후 s_ready=0일 때 받아들인 beat를 skid buffer가 중복 출력 | `fifo/unit_post_reset_test`, `fifo_d4/unit_post_reset_test`, `skid/unit_post_reset_test` | 영구 known_fail (RTL 담당자 결정, 2026-11-14) |
| BUG-002 | bug | open | WDMA가 AW 수락 전에 W beat를 보내고, 그 beat를 잘못 세어 멈춤 | `top/dma_aw_backpressure_test` | 2026-11-18 release 판정, 조건부 출시 |
| NOTE-001 | note | open | WDMA burst 주소 계산 루프의 100 MHz 타이밍 여유가 거의 없음 | - | - |
| BUG-003 | bug | open | 작업을 한 번 끝낸 뒤에는 W FSM이 RUN에 남아, AW보다 먼저 온 W beat를 이전 burst 길이로 셈 | `top/dma_aw_wait_after_job_test` | - |
| BUG-004 | bug | open | B 응답이 W burst보다 느리면 W->B FIFO(깊이 4)가 넘쳐 B 항목이 버려지고, WLAST가 틀리며 멈춤 | `top/dma_slow_b_test` | - |
| BUG-005 | bug | open | ap_start를 에지로만 받아, 작업 중 start나 auto_restart 뒤에는 리셋 전까지 다시 시작하지 않음 | `top/dma_start_busy_test`, `top/dma_auto_restart_test` | - |
| BUG-006 | bug | open | 작업 도중 리셋하면 adder에 남은 beat가 리셋 뒤 AW 없는 W로 나가고, 그 뒤 모든 작업의 데이터가 밀림 | `top/dma_reset_mid_job_test` | - |
| BUG-007 | bug | open | RDMA/WDMA beat 카운터가 24비트라 128MiB 이상 전송하면 일부만 복사하고 done, 128MiB 배수면 멈춤 | `top/dma_size_128mib_test` | - |
| NOTE-002 | note | open | 작업 중 VALUE_TO_ADD를 바꾸면 그 뒤에 R로 받는 beat부터 새 값이 더해짐 | - | - |
| NOTE-003 | note | open | 리셋이 걸린 뒤 2사이클 동안 DUT의 WVALID가 1로 남음 | - | - |
