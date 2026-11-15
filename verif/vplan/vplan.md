# 검증 계획 (계속 갱신하는 문서)

표시: ✅ 완료 · 🚧 진행 중 · ⬜ 계획

## P1: 단위 레벨 (`verif/tb/unit`, `unit_env_pkg`, `unit_test_pkg`)
| 기능 | 블록 | 테스트 | 검사 | 커버리지 | 상태 |
|---|---|---|---|---|---|
| 손실 없이 순서대로 전달 | fifo, skid, adder | 모든 unit 테스트 | 순서 비교 scoreboard, 남은 beat/예상 밖 beat | beat 개수 | ✅ |
| adder lane별 덧셈, 32비트 wrap | adder | rand, fixed_side | lane별 덧셈 모델 | `cp_lo/hi_carry` 있음/없음 | ✅ |
| adder 8비트 lane (top 설정) | adder8 | 모든 unit 테스트 | 같은 모델, lane_bw=8 | | ✅ |
| ctrl_constant를 beat마다 샘플링 | adder | rand (side가 beat마다 바뀜) | 모델이 handshake 시점의 side를 사용 | `cp_side` | ✅ |
| value_to_add 고정 (top의 사용 방식) | adder | fixed_side | 같음 | | ✅ |
| backpressure, FIFO 가득 참 | fifo, fifo_d4 | backpressure | scoreboard | `cp_in` stall 상태, `stall_release` | ✅ |
| 빌 때까지 배출, 띄엄띄엄 입력 | 전부 | trickle | scoreboard | `cp_out` idle | ✅ |
| 연속(back-to-back) 최대 처리량 | 전부 | smoke | scoreboard | `b2b` 전이 | ✅ |
| 리셋 직후 첫 사이클의 valid | skid, fifo | post_reset | scoreboard | | ❌ BUG-001 |
| valid/ready 프로토콜 (유지, X 없음) | 모든 포트 | 전부 | `vr_if`의 SVA (UVM_ERROR) | | ✅ |

## P2: top 레벨 `dma_ip_top` (`verif/tb/top`, `dma_env_pkg`, `dma_seq_pkg`, `dma_test_pkg`)
env: AXI4-Lite master (`axil_agent`, 레지스터 맵 `dma_reg_map.sv`, RAL 없음) → DUT → AXI4 slave agent + 메모리 모델 (`axi4_slv_pkg`).
작업마다: `SW/mem_copy_test.c`와 같은 순서로 레지스터를 설정하고, 시작하고, 완료(polling 또는 IRQ)를 기다린 뒤 메모리를 비교합니다.

| 기능 | 테스트 | 검사 | 커버리지 | 상태 |
|---|---|---|---|---|
| 레지스터 리셋 값 (10개 전부, 32비트 전체, AP_CTRL idle=1과 ISR 포함) | dma_reg_reset_test | `dma_reg_reset_seq` | | ✅ |
| 레지스터 R/W (AP_CTRL, ISR을 뺀 모든 RW 레지스터): walking 1/0, 사용 안 하는 비트는 0 | dma_reg_bitbash_test | `dma_reg_bitbash_seq` (검사 390회) | | ✅ |
| 바이트마다 dst = src + value_to_add[7:0] | 모든 작업 테스트 | dst 모든 바이트 비교. dst는 ~기대값으로 미리 오염 | `cp_value` 0/1/255/그 외 | ✅ |
| value_to_add[31:8] 무시 | 모든 작업 테스트 | 같음 | `cp_upper` | ✅ |
| 넘침/모자람 없음, 원본 보존 | 모든 작업 테스트 | dst 앞뒤 64B 보호 영역, src 스냅샷 | | ✅ |
| burst는 INCR, 8B size와 정렬, 16 beat 이하 | 전부 | `axi4_slv_monitor` 검사 | `cp_len` 1/2-15/16 | ✅ |
| 4KB 경계 분할 | dma_4kb_test (+ 랜덤) | AXI_4KB 검사, SB_RANGE | `split_at_4k` rd/wr | ✅ |
| AR, AW의 beat 합계 = bytes/8 | 모든 작업 테스트 | SB_BEATS | `cp_beats` 1..8192 | ✅ |
| AXI master 프로토콜 (유지, X) | 전부 | `axi4_if`의 SVA | | ✅ |
| R/W/AR/B backpressure, R 지연 | rand, backpressure, large | 위 검사 전부 | | ✅ |
| AWREADY backpressure | dma_aw_backpressure_test | WLAST 위치, 완료 여부 | | ❌ BUG-002 |
| AP_CTRL.done polling으로 완료 (읽으면 지워짐) | 대부분 | done 비트, GIE=0이면 인터럽트는 0 유지 | `cp_mode` | ✅ |
| 인터럽트로 완료 (GIE/IER/ISR) | dma_irq_test, rand | ISR[0] 설정, ISR을 읽으면 IRQ 내려감 | `cp_mode` | ✅ |
| 정확한 경계 크기 (1 beat, 16 = burst 하나 가득, 512 = 4KB 페이지 하나) × polling과 IRQ 완료 | dma_size_edge_test | 바이트 비교, SB_BEATS, IRQ 검사 | `x_size_mode` one/max_burst/page × 두 모드 | ✅ |
| 연속 작업, idle로 복귀 | 모든 다중 작업 테스트 | 작업마다 AP_CTRL.idle | | ✅ |
| transfer_byte = 0 / 8의 배수가 아님 | (테스트 안 함) | SW가 금지함. 0이면 RTL이 멈춤 | | ⬜ 사양 밖 |
| auto_restart | (테스트 안 함) | | | ⬜ |
