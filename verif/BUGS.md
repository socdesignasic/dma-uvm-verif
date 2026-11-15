# RTL 버그 목록 (검증에서 발견)

검증 흐름은 `HW/` 아래 RTL을 수정하지 않습니다. 버그마다 재현 테스트가 있고, 그 테스트는
`verif/sim_cfg.json`에 `known_fail`로 등록돼 있어서 CI는 초록색으로 유지됩니다 (XFAIL / skipped로 보고).
RTL이 고쳐지면 테스트가 XPASS가 되면서 CI가 실패하고, 그것이 `known_fail` 항목을 지우라는 신호입니다.

## BUG-001: 리셋 후 `s_ready=0`일 때 받아들인 beat를 skid buffer가 중복 출력
- **블록:** `HW/peri_ip/skid_buffer.v` (`sync_fifo` 안의 IN, OUT 단에도 있음)
- **상태:** won't fix (RTL 담당자 결정, 2026-11-14). 영구 `known_fail`로 둡니다.
- **재현:** `python scripts/sim.py run --tb skid --test unit_post_reset_test --seed 1`
  (`fifo`, `fifo_d4`도 같음. 모든 seed에서 실패)
- **증상:** 첫 beat가 두 번 나오고, 그 뒤의 beat가 모두 하나씩 밀립니다.
  ```
  105ns  s_valid=1, s_ready=0   (AXI-Stream 규칙상 handshake 아님)
  115ns  out: 0x..6f004183        (105ns에 잡힌 beat)
         in : 0x..6f004183 수락  (이제 s_ready=1. 소스가 다시 보냄)
  125ns  out: 0x..6f004183        <- 중복
  ```
- **원인:** `s_ready_reg`는 0으로 리셋되지만, `PIPE` 상태에서는 하위 단이 ready이기만 하면
  **`s_ready_reg`를 확인하지 않고** `m_valid_reg <= s_valid`로 값을 받습니다. 리셋 직후 첫 사이클에는
  `s_ready=0`이므로, `valid`를 바로 켜는 소스(규격상 허용)의 beat가 handshake 없이 잡히고,
  소스가 그 beat를 다시 보내서 중복됩니다.
- **수정 제안 (RTL 담당자 승인 필요):** 값을 받을 때 handshake 조건을 넣습니다. 예:
  `m_valid_reg <= s_valid & s_ready_reg;`,
  `m_valid_temp_reg <= s_valid & s_ready_reg;`.
- **dma_ip_top에 미치는 영향:** 실제로는 낮음. FIFO 입력은 RDMA가 주는데, RDMA는 리셋 한참 뒤
  `ap_start` 이후에야 시작하므로 지금 보드에서는 이 구간에 걸리지 않습니다. 리셋 직후부터 valid를
  켜는 상위 블록이 붙으면 걸립니다.

## BUG-002: WDMA가 AW 수락 전에 W beat를 보내고, 그 beat를 잘못 세어 멈춤
- **블록:** `HW/dma_ip/WDMA/wdma.v`
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)
- **재현:** `python scripts/sim.py run --tb top --test dma_aw_backpressure_test --seed 1`
  (어떤 seed든, 쓰기 데이터가 준비된 동안 AWREADY를 0으로 잡는 slave면 모두 재현)
- **증상:** `WLAST`가 늦게 나오고 (16번째가 아니라 19번째 beat), 그 뒤 burst가 모두 밀리며,
  B 응답 개수가 총합에 도달하지 못해 **`ap_done`이 끝내 나오지 않습니다 (멈춤)**.
  메모리 모델이 beat 순서대로 쓰기 때문에 데이터 바이트 자체는 올바른 주소에 들어갑니다.
  ```
  715/745/755ns  W beat #1-3 수락   (아직 AW 수락 없음, W FSM은 IDLE)
  765ns          AW #0 수락 (16 beat)
  1135ns         beat #16, WLAST=0  <- slave는 여기서 WLAST를 기대
  1235ns         beat #19, WLAST=1
  ```
- **원인:** `m_axi_gmem_WVALID = s_valid` (FIFO가 비어 있지 않음)와 `s_ready = WREADY`가
  W 상태 머신으로 막혀 있지 않습니다. `c_state_w == S_IDLE`(AW->W FIFO에 아직 AW 없음)인 동안
  `r_burst_cnt_w`는 0에 고정되므로, 그때 수락된 beat는 세지 않습니다. 버스 입장에서 W가 AW보다
  먼저 오는 것은 AXI 규격상 허용되지만, WDMA 자체의 WLAST/B 계산은 그런 일이 없다고 가정합니다.
- **수정 제안 (RTL 담당자 승인 필요):**
  `assign m_axi_gmem_WVALID = s_valid & w_s_run_w;`,
  `assign s_ready = m_axi_gmem_WREADY & w_s_run_w;`
- **보드에 미치는 영향:** 실제로 멈출 위험이 있습니다. Zynq HP 포트나 AXI interconnect / SmartConnect가
  AWREADY를 늦출 수 있습니다. 지금까지 기존 보드 구성이 동작한 것은 AWREADY가 보통 빨리 돌아오기 때문입니다.
- **검증에 미치는 영향:** 다른 top 테스트는 모두 AWREADY=1로 둡니다 (W/AR/R/B backpressure는 계속 랜덤).
  그래서 나머지 설계는 여전히 검사됩니다. AWREADY 지연은 `dma_aw_backpressure_test`만 다루고,
  이 테스트는 `known_fail`로 등록돼 있습니다.

---
# 설계 노트 (기능 버그 아님)

## NOTE-001: WDMA burst 주소 계산 루프의 100 MHz 타이밍 여유가 거의 없음
- **발견:** `python scripts/fpga.py ooc` (P6), xc7z020clg400-1, ap_clk 10 ns, 단독(out-of-context) 배치배선
- **결과:** WNS = **+0.014 ns** (만족하지만 여유가 사실상 없음). WHS = +0.125 ns. LUT 1931개 / FF 5315개.
- **critical path:** `u_wdma/r_hs_data_cnt_reg[1] -> r_hs_data_cnt_reg[21]`, 로직 20단
  (CARRY4 12개). `r_hs_data_cnt`가 `remain_hs`, 16 beat 제한, 4KB 경계 계산
  (`last_addr_in_burst`, `boudary_burst_len_4k`), `burst_len_aw`를 거쳐 다시 `r_hs_data_cnt`로 돌아오는 것이
  모두 한 사이클 안에 있습니다. `rdma`도 구조가 같습니다.
- **전체 시스템 @100 MHz (PS7 + interconnect + ILA):** 기본 구현 전략으로는 같은 루프가
  손으로 만든 프로젝트와 CD 빌드 모두에서 **타이밍을 못 맞춥니다**:

  | 빌드 | 구현 전략 | WNS | 실패 endpoint | 최악 경로 |
  |---|---|---|---|---|
  | 손으로 만든 `mem_copy_vivado` | 기본 | -0.201 ns | 6 | RDMA `r_hs_data_cnt` |
  | CD `71cdca3` | 기본 | -0.347 ns | 12 | RDMA `r_hs_data_cnt` (22단) |
  | CD `71cdca3` | `Performance_ExplorePostRoutePhysOpt` | **+0.003 ns** | 0 | WDMA `r_hs_data_cnt` (17단) |

  이제 `scripts/fpga.py system`은 기본으로 explore 전략을 쓰고, 배선 전후에 phys_opt를 켭니다.
  타이밍은 맞지만 여유가 +0.003 ns로 매우 얇아서, 배치가 달라지거나 RTL/BD가 조금만 바뀌어도 다시
  실패할 수 있습니다. CI는 WNS < 0이면 FPGA 단계를 실패로 처리합니다.
- **개선 방안 (RTL 담당자):** `burst_len_aw` / 경계 길이를 한 사이클 먼저 레지스터에 저장합니다.
  AW FSM이 이미 `S_PRE`에서 한 사이클을 쓰므로, 거기서 미리 계산해 둘 수 있습니다.
