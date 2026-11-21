# UVM 코드 구조

전체 저장소 구성은 [ARCHITECTURE.md](ARCHITECTURE.md), 실행 흐름은 [FLOW.md](FLOW.md)를 참고하세요.

## 규칙

- **파일 하나 = 클래스 하나, 파일 이름 = 클래스 이름입니다.** 예: `dma_scoreboard` → `dma_scoreboard.svh`.
  driver는 driver 파일에만, scoreboard는 scoreboard 파일에만 있습니다.
- **`*_pkg.sv`는 목차입니다.** import, 패키지 공용 typedef/상수, 그리고 클래스 파일을 `` `include ``하는 줄만 담습니다.
  filelist(`.f`)에는 패키지 파일만 적고, 패키지가 include하는 역할 폴더마다 `+incdir+`를 둡니다.
- **top TB는 RAL(`uvm_reg`)을 씁니다.** 레지스터는 `dma_reg_block`(`regmodel`)의 frontdoor로 읽고 씁니다.
  정의되지 않은 비트도 RO 필드로 모델링해 32비트 전체를 비교합니다. 주소 상수는 `dma_reg_map.svh`에 있습니다.
  `axil_reg_base_seq`의 `write_reg()`/`read_reg()`는 RAL 밖에서 직접 접근할 때 쓰는 기본 클래스로 남아 있습니다.
- **자극(stimulus)은 시퀀스에 둡니다.** env는 컴포넌트를 만들고 연결하는 일만 합니다.

## 디렉터리

```
verif/
├─ rtl.f                      RTL 파일 목록
├─ vip/                       재사용 VIP (DUT를 모름)
│  ├─ stream/                 valid/ready 스트림 (unit TB)
│  │    stream_if.sv  stream_pkg.sv
│  │    stream_item.svh  stream_cfg.svh  stream_sequencer.svh
│  │    stream_source_driver.svh  stream_sink_driver.svh  stream_monitor.svh  stream_agent.svh
│  │    stream_rand_seq.svh
│  ├─ axil/                   AXI4-Lite 마스터 (top TB, DUT 제어 레지스터)
│  │    axil_if.sv  axil_pkg.sv
│  │    axil_cfg.svh  axil_item.svh  axil_sequencer.svh  axil_driver.svh  axil_monitor.svh  axil_agent.svh
│  │    axil_reg_adapter.svh    ← uvm_reg <-> axil_item
│  │    axil_reg_base_seq.svh   ← write_reg / read_reg
│  └─ axi4_slave/             AXI4 슬레이브 + 메모리 모델 (top TB, DUT m00)
│       axi4_if.sv  axi4_slave_pkg.sv
│       axi4_slave_cfg.svh  axi4_mem.svh  axi4_item.svh  axi4_wb_item.svh
│       axi4_slave_driver.svh  axi4_slave_monitor.svh  axi4_slave_agent.svh
├─ top/                       DMA 전체 TB
│  ├─ top.f  tb_dma.sv  dma_reset_if.sv  dma_ap_ctrl_sva.sv
│  ├─ env/         dma_env_pkg.sv  dma_env_cfg.svh  dma_env.svh  dma_vsqr.svh
│  ├─ model/       dma_reg_map.svh  dma_job.svh  dma_reg_block.svh
│  │               dma_ap_ctrl_reg.svh  dma_gie_reg.svh  dma_ier_reg.svh  dma_isr_reg.svh  dma_data_reg.svh
│  │               dma_ref_model.svh  dma_predictor.svh
│  ├─ scoreboard/  dma_scoreboard.svh
│  ├─ coverage/    dma_coverage.svh
│  ├─ seq/         dma_seq_pkg.sv  dma_job_vseq.svh  dma_pipeline_vseq.svh  dma_busy_reg_vseq.svh
│  │               dma_reset_vseq.svh  dma_reg_bitbash_vseq.svh
│  └─ test/        dma_test_pkg.sv  dma_base_test.svh  dma_*_test.svh  dma_error_catcher.svh
├─ unit/                      블록 단위 TB (sequence는 vip/stream의 것을 씀, seq/ 없음)
│  ├─ unit_common.f  fifo.f  skid.f  adder.f
│  ├─ tb_fifo.sv  tb_skid.sv  tb_adder.sv  tb_unit_common.svh
│  ├─ env/         unit_env_pkg.sv  unit_env_cfg.svh  unit_env.svh
│  ├─ scoreboard/  unit_scoreboard.svh
│  ├─ coverage/    unit_coverage.svh
│  └─ test/        unit_test_pkg.sv  unit_base_test.svh  unit_*_test.svh
├─ ref_adder/                 참고 코드 이식 TB (XFAIL 예시)
│     ref_adder.f  ref_adder_fixed.f  ref_adder_tb.sv  my_adder_fixed.sv
└─ selftest/                  sim.py 판정 자체 시험 TB
      xsim_msgs.f  xsim_msgs_tb.sv
```

패키지 의존은 한 방향입니다.

```
top : axil_pkg, axi4_slave_pkg → dma_env_pkg → dma_seq_pkg → dma_test_pkg → tb_dma
      (dma_reset_if.sv는 패키지 앞, dma_ap_ctrl_sva.sv는 패키지 뒤 tb_dma 앞. 순서는 top.f)
unit: stream_pkg → unit_env_pkg → unit_test_pkg → tb_fifo / tb_skid / tb_adder
```

---

## 1. Agent

### `stream_agent`: 범용 valid/ready 에이전트 (unit TB)

| 파일 | 역할 |
|---|---|
| `stream_item.svh` | `data[63:0]`, `side[31:0]`(adder의 더할 값), `delay`(valid 전 쉬는 사이클 수) |
| `stream_cfg.svh` | `mode`(MASTER/SLAVE/PASSIVE), `post_reset_idle`, slave backpressure 설정값(`ready_pct`, `stall_pct`, `max_stall`) |
| `stream_sequencer.svh` | `stream_item` sequencer (master 모드에서만 생성) |
| `stream_source_driver.svh` | sequence에서 item을 받아 valid/data/side를 올리고 ready가 올 때까지 유지 |
| `stream_sink_driver.svh` | sequencer 없이 혼자 무작위 ready를 냄. 가끔 길게 멈춤(stall) |
| `stream_monitor.svh` | `valid && ready`인 사이클마다 item을 만들어 analysis port로 보냄 |
| `stream_agent.svh` | `cfg.mode`에 따라 위 컴포넌트를 골라 만들고 연결 |
| `stream_rand_seq.svh` | item을 n개 생성. 코너값(0, 전부 1, MSB 등)은 절차적으로 섞음 (XSim `dist` 버그 회피) |

하나의 에이전트를 모드만 바꿔서 입력 쪽(MASTER)과 출력 쪽(SLAVE)에 모두 씁니다.

### `axil_agent`: AXI4-Lite 마스터 (top TB)

| 파일 | 역할 |
|---|---|
| `axil_cfg.svh` | driver 타이밍 노브 `max_aw_w_skew`(쓰기마다 AW/W 순서: 같은 사이클 / AW 먼저 / W 먼저, 간격 1..max 에지), `max_ready_delay`(B/R 응답마다 0..max 에지, VALID를 본 뒤 READY를 올림). 기본 0이면 driver는 `$urandom`을 부르지 않고 사이클 동작은 노브를 넣기 전과 같음 (단 같은 seed의 기존 테스트 자극은 XSim에서 바뀔 수 있음). driver는 skew를 쓰기 시작 때, READY 지연을 B/R 대기 시작 때 읽음. **노브를 켠 채 테스트 중간 리셋은 지원하지 않음** (`dma_reset_vseq`가 `RESET_CFG`로 멈춤). agent가 config_db `cfg`로 받고 없으면 기본값 |
| `axil_item.svh` | 읽기 또는 쓰기 한 건 (`write`, `addr`, `data`, `resp`) |
| `axil_sequencer.svh` | `axil_item` sequencer |
| `axil_driver.svh` | 쓰기: AW와 W를 (기본) 같은 사이클에 내고 각각 handshake 후 B를 받음. 읽기: AR 후 R을 받아 item에 `data`/`resp`를 채움. `axil_cfg` 노브를 켜면 AW/W 순서와 간격, BREADY/RREADY 지연을 접근마다 고르고, 실제로 늦춘 수를 `AXIL_TIMING` 줄에 남김 |
| `axil_monitor.svh` | 버스를 driver와 따로 관찰해 접근마다 `axil_item`을 `ap`로 보냄. 쓰기는 AW와 W가 모두 끝난 에지, 읽기는 R 에지(`addr`는 짝이 되는 AR 주소). B/R 응답이 OKAY가 아니면 `AXIL_RESP` 에러. 리셋 에지의 handshake는 보지 않고, 짝이 안 맞은 대기 큐(AW, W, B, R)를 비움. 결함 주입 노브 `inj_rd_*`(기본 꺼짐, checker self-test용) |
| `axil_reg_adapter.svh` | `uvm_reg` 접근과 `axil_item`을 서로 바꿈. RAL frontdoor와 `uvm_reg_predictor`가 씀 (strobe는 항상 4바이트 전부) |
| `axil_agent.svh` | sequencer + driver + monitor. monitor가 본 접근을 `ap`로 내보냄. `cfg`(`axil_cfg`)를 driver에 넘김 |
| `axil_reg_base_seq.svh` | 레지스터 시퀀스의 기본 클래스. `write_reg(addr, data)`, `read_reg(addr, data)`. 응답이 OKAY가 아니면 `UVM_ERROR` |

### `axi4_slave_agent`: 반응형 AXI4 슬레이브 + 메모리 모델 (top TB, DDR 대신)

| 파일 | 역할 |
|---|---|
| `axi4_slave_cfg.svh` | 채널별 ready 확률, `aw_fixed_wait`(BUG-002 재현용), R/B 지연(`max_b_latency`, 하한 `min_b_latency`), R 사이 쉬는 사이클 확률. driver가 매번 다시 읽으므로 실행 중에 바꿔도 안전합니다. 결함 주입 노브 `inj_r_flip`, `inj_r_addr`, `inj_w_shift_end`(기본 0, checker self-test용) |
| `axi4_mem.svh` | `bit[7:0] m[bit[31:0]]` 희소 바이트 메모리. `wr8`/`rd8`/`has`/`rd64`/`wr64` |
| `axi4_item.svh` | AR/AW 한 건 (addr, len, size, burst) |
| `axi4_wb_item.svh` | monitor가 본 W beat 하나(`data`, `strb`, `last`, `before_aw`, `t`) 또는 B 응답 하나(`resp`, `id`, `t`). `is_b`로 구분 |
| `axi4_slave_driver.svh` | 슬레이브 쪽 신호 구동. 아래 6개 task를 `fork`로 동시에 실행. 리셋이 걸리면 ready/valid를 0으로 두고 진행 중인 burst와 큐를 버립니다(메모리와 카운터는 유지). 리셋이 풀린 첫 에지에 task를 다시 시작 |
| `axi4_slave_monitor.svh` | AR/AW handshake를 `axi4_item`로 만들어 `ar_ap`/`aw_ap`로 보내고 burst 규칙을 검사. W beat와 B 응답은 `axi4_wb_item`으로 `w_ap`/`b_ap`로 보냄 (검사 없음). 리셋 에지의 handshake는 보지 않고, 리셋에서 W/AW 짝 맞춤을 처음부터 다시 함 |
| `axi4_slave_agent.svh` | cfg + mem + driver + monitor. `mem`과 `ar_ap`/`aw_ap`/`w_ap`/`b_ap`를 env에 노출 |

```
 driver:  ar_channel ─→ ar_q ─→ r_channel        (요청 순서대로, 첫 beat 지연과 중간 쉬는 사이클을 무작위로)
          aw_channel ─→ aw_q ─┐
          w_channel  ─→ w_q  ─┴→ write_engine ─→ b_q ─→ b_channel
 monitor: AR/AW handshake ─→ check_burst ─→ ar_ap / aw_ap
          W / B handshake ─→ w_ap / b_ap       (버스만 봄, driver 큐는 읽지 않음)
```

- **monitor 검사:** burst마다 INCR인지, 크기가 8바이트인지, 8바이트 정렬인지, 16 beat 이하인지, 4KB 경계를 넘지 않는지 확인합니다.
- **driver 검사:**
  - 마지막 beat에서만 WLAST가 오는지
  - 초기화하지 않은 메모리를 읽지 않는지
  - 시뮬레이션이 끝날 때 처리하지 못한 AR/AW/W/B가 남지 않았는지
- **W가 AW보다 먼저 와도 받습니다.** AXI 규칙상 합법이기 때문입니다. `write_engine`이 나중에 AW와 W beat를 짝짓습니다. BUG-002의 WLAST 오류가 바로 여기서 잡혔습니다.

## 2. Env

### Top (`top/env/`, `top/model/`, `top/scoreboard/`, `top/coverage/`)

데이터 흐름 (이 문서가 원본입니다. 연결은 `dma_env.svh`):

```
 sequence ─ regmodel frontdoor ─→ axil_agt.sqr ─→ axil_driver ─→ DUT 제어 레지스터
 axil_monitor (버스 관찰) ─ ap ─→ dma_predictor ─ reg_ap ─→ uvm_reg_predictor ─→ regmodel mirror
                                       │   (predictor가 먼저 보고, 그다음 mirror 갱신)
                                       ├─ job_ap ─→ dma_scoreboard.job_fifo        (PRE 진입 에지에 만든 job.
                                       │                                           리셋으로 중단하면 같은 handle을 t_abort를 달아 다시 보냄)
 mem_agt.b_ap ─────────────────────────┴─→ dma_predictor.b_fifo                    (job 완료 판단)
 mem_agt.w_ap / b_ap ──────────────────────→ dma_scoreboard.w_fifo / b_fifo
 mem_agt.ar_ap / aw_ap ──┬─────────────────→ dma_scoreboard.burst_imp
                         └─────────────────→ dma_coverage.burst_imp (cg_burst)
 dma_scoreboard.done_ap ───────────────────→ dma_coverage.job_fifo (cg_job)         (마지막 B까지 검사한 job)
```

- **mirror 갱신:** auto predict를 끄고 위 경로로만 갱신합니다. 읽을 때 RAL 자체 비교(`check_on_read`)도 끕니다. 정확성 검사는 `dma_predictor`가 합니다.
- **`dma_predictor`:** 사이클 모델로 모든 AXI-Lite 읽기값(32비트 전체)과 interrupt 핀을 비교하고, job을 만듭니다. 모델의 규칙은 `dma_predictor.svh` 머리 주석이 원본이고, 여기에는 요점만 적습니다.
  - **start 모델:** ap_ctrl_hs 관례(TB가 정한 정의, RTL 식이 아님)로 level start를 모델링합니다. 작업 중에 쓴 start는 대기했다가 지금 작업이 끝난 뒤 실행되고, `auto_restart`는 `control_s_axi.v` 식 그대로 다시 시작합니다. RTL은 start를 에지로만 받으므로(BUG-005) 그 경우 모델은 다음 job을 예측하고 DUT는 하지 않아 테스트가 FAIL합니다.
  - **job 생성:** 모델이 PRE에 들어가는 에지에서 그때의 shadow 레지스터로 만듭니다.
  - **VALUE_TO_ADD:** 작업 중에 바꾸면 그 뒤 R beat부터 새 값입니다(NOTE-002). predictor가 R handshake를 세어 beat별 기대값을 바꿉니다(`PRED_VALUE` 로그).
  - **큰 job:** 1MiB를 넘으면 기대 목록을 미리 만들지 않고 계산식으로 구합니다(lazy). src와 dst가 겹치면 `PRED_UNSUPPORTED`입니다.
  - **리셋:** 리셋을 본 에지에서 실행 중인 job을 중단하고(`PRED_ABORT`), 풀린 첫 에지에 모델, shadow, mirror를 리셋 값으로 되돌립니다. 흐름은 5절 "리셋"에 적습니다.
- **scoreboard와 coverage는 monitor와 predictor가 본 것만** 씁니다. 자극 쪽 sequence의 값은 쓰지 않습니다.

| 파일 | 역할 |
|---|---|
| `dma_reg_map.svh` | 레지스터 주소(`ADDR_AP_CTRL` … `ADDR_VALUE_TO_ADD`)와 AP_CTRL/ISR 비트 위치 상수 |
| `dma_reg_block.svh` | RAL 블록. 레지스터 10개를 map에 올리고, build에서 AP_CTRL과 ISR에 `NO_REG_BIT_BASH_TEST` resource를 넣음 |
| `dma_ap_ctrl_reg.svh`, `dma_gie_reg.svh`, `dma_ier_reg.svh`, `dma_isr_reg.svh`, `dma_data_reg.svh` | 레지스터 클래스 5개. `dma_data_reg`는 32비트 데이터 레지스터 6개가 같이 씀 |
| `dma_job.svh` | DMA 실행 한 번: `src`, `dst`, `bytes`, `value`, `mode`(polling 또는 IRQ)과 기대값 `exp` |
| `dma_ref_model.svh` | job 하나의 기대 동작: 기대 AR/AW 목록, 기대 W 데이터, start 시점 src와 dst(앞뒤 guard 포함) 스냅샷. 1MiB를 넘는 job은 목록 대신 `n_bursts`/`burst_at` 계산식. VALUE 변경 목록(beat별 값) |
| `dma_predictor.svh` | 위 설명. 오류 ID는 아래 |
| `dma_env_cfg.svh` | 슬레이브 cfg(`slv_cfg`), AXI-Lite master 타이밍 노브(`ctl_cfg`, env가 config_db로 `axil_agt`에 넘김), 클럭 주기(시간 예산 계산용) |
| `dma_scoreboard.svh` | job 단위 검사 (아래) |
| `dma_coverage.svh` | `cg_job`, `cg_burst` |
| `dma_vsqr.svh` | job virtual sequencer. `dma_job_vseq`가 쓰는 핸들: AXI-Lite sequencer(`axil_sqr`), `regmodel`, 메모리 모델(`mem`), `mem_drv`(JOB_TIMEOUT 메시지의 진행 상황, R handshake 수 `n_rd_beats`), `ctl_vif`, `rst_vif`(리셋 interface), `cfg`. `rst_vif`는 tb_dma가 config_db로 넣고 없으면 `NO_VIF` fatal |
| `dma_env.svh` | `axil_agt`, `mem_agt`, `regmodel`, `adapter`, `reg_predictor`, `pred`, `sb`, `cov`, `vsqr` 생성과 연결. `ctl_vif`(클럭, 인터럽트)와 `clocks(n)` |

레지스터 맵:

| 오프셋 | 상수 | 비고 |
|---|---|---|
| 0x00 | `ADDR_AP_CTRL` | start[0], done[1](COR), idle[2], ready[3](COR), auto_restart[7], interrupt[9] |
| 0x04 / 0x08 / 0x0C | `ADDR_GIE` / `ADDR_IER` / `ADDR_ISR` | ISR은 읽으면 지워짐(COR) |
| 0x10 / 0x14 | `ADDR_RDMA_TRANSFER_BYTE` / `ADDR_RDMA_MEM_PTR` | |
| 0x18 / 0x1C | `ADDR_WDMA_TRANSFER_BYTE` / `ADDR_WDMA_MEM_PTR` | |
| 0x20 / 0x24 | `ADDR_AXI00_PTR0` / `ADDR_VALUE_TO_ADD` | |

`dma_predictor` 검사 (모든 AXI-Lite 읽기 32비트 전체와 interrupt 핀):
- **`REG_RESET`:** 리셋 뒤 쓴 적 없고 job 전인 레지스터가 리셋 값과 같은지
- **`REG_BITBASH`:** 그 밖에서 예약 비트(상수 0)와 RW 필드(mirror 값)가 맞는지
- **`IRQ`:** ISR[0], AP_CTRL.done, interrupt 핀(매 에지 예측과 비교)
- **`REG_STATUS`:** start, idle, ready, interrupt[9], ISR[1]
- **`PRED_UNSUPPORTED`:** 모델이 다루지 않는 경우 (바이트 수 0 또는 8의 배수 아님, RDMA와 WDMA 값이 다름, 맵에 없는 주소, strobe가 4'hF가 아닌 쓰기, 같은 에지의 쓰기와 읽기, 테스트 끝에 R 없이 남은 AR, B 장부가 모델과 안 맞음, 1MiB 넘는 job의 src/dst 겹침)

`dma_scoreboard` 검사 (job마다. 기대 목록과 스냅샷은 `dma_ref_model`이 start 시점에 만듦):
- **`SB_AR_LIST`, `SB_AW_LIST`:** AR/AW가 올 때마다 기대 목록의 다음 항목과 주소, len, size, burst 비교
- **`SB_RANGE`:** burst가 src/dst 창 안에 있는지
- **`SB_WDATA`, `SB_WSTRB`:** W beat마다 기대 데이터와 strobe 비교 (W가 AW보다 먼저 와도 beat 순서대로 짝지음)
- **마지막 B 뒤** (B 수 = 기대 AW 수):
  - `SB_DATA`: 모든 dst 바이트가 start 시점 스냅샷으로 계산한 기대값과 같은지
  - `SB_OVERRUN`: dst 앞뒤 guard가 바뀌지 않았는지
  - `SB_SRC`: src가 바뀌지 않았는지
  - `SB_BEATS`: 본 beat 합과 남은 기대 목록
- **리셋으로 중단된 job:** 오류가 아니라 정보입니다(`SB_JOB ... ABORTED`). 같은 시각 항목은 시각으로 소속을 정합니다(중단 에지 이하면 중단한 job 것).
- **`SB_DUP_JOB`:** 같은 job이 리셋 중단 표시 없이 다시 온 경우
- **`SB_NO_JOB_BUS`:** 실행 중인 job 없이 AR/AW/W/B가 온 경우 (리셋 뒤 DUT가 혼자 버스를 구동해도 여기서 잡힘)
- **`SB_UNFINISHED`:** 끝나지 않은 job (테스트 끝, 또는 다음 job이 올 때)
- **`SB_NO_JOBS`:** 마지막 B까지 간 job이 하나도 없는 경우. 레지스터 전용 테스트는 `expect_jobs = 0`으로 끕니다.

**`APCTRL_SVA`:** `dma_ap_ctrl_sva.sv`의 assertion 7개(`a_ap_start_hold`, `a_ap_ready_with_start`, `a_ap_ready_pulse`, `a_ap_done_pulse`, `a_ap_idle_excl`, `a_ap_idle_leave`, `a_ap_idle_fall_start`)가 DUT 안쪽 ap_ctrl_hs 신호(`ap_start`, `ap_done`, `ap_idle`, `ap_ready`)를 봅니다. 파일 끝의 `bind`로 `dma_ip_top`에 들어가므로 RTL은 고치지 않습니다. 리셋 중(`disable iff`)은 검사하지 않고, 실패하면 `UVM_ERROR [APCTRL_SVA]`입니다. `a_ap_idle_leave`는 H1/H2(BUG-005)가 어깁니다.

`dma_checker_test`는 이 검사들이 실제로 오류를 내는지 확인합니다 (4절 checker self-test).

`dma_coverage` (`cg_job`는 scoreboard `done_ap`의 job, 끝나지 않은 job은 샘플링하지 않음):
- **`cg_job`:**
  - 크기 구간(1, 2~15, 16, 17~511, 512, 513 이상)
  - value 코너, value 상위 비트가 무시되는지
  - 완료 모드
  - src/dst 4KB 경계 통과 여부
  - 크기 × 모드 교차
- **`cg_burst`:** 방향 × 길이, 방향 × "4KB 경계에서 잘린 burst"

### Unit (`unit/env/`, `unit/scoreboard/`, `unit/coverage/`)

```
 in_agt (MASTER) → DUT → out_agt (SLAVE, 무작위 ready)
      └─ ap ─→ sb.in_imp / cov        out_agt.ap ─→ sb.out_imp
```

| 파일 | 역할 |
|---|---|
| `unit_env_cfg.svh` | `model`(`MODEL_PASS`: FIFO/skid, `MODEL_ADD`: adder), `lane_bw`, in/out agent cfg |
| `unit_scoreboard.svh` | 입력이 오면 기대값을 큐에 넣고, 출력이 오면 순서대로 비교. 끝날 때 큐에 남은 것이 있으면 에러 |
| `unit_coverage.svh` | `cg_beat`(데이터/side 코너, lane별 carry), `cg_cycle`(매 사이클 {valid, ready}, 연속 전송, stall 해제) |
| `unit_env.svh` | 에이전트 2개 + scoreboard + coverage 생성과 연결 |

## 3. Sequences (`top/seq/`)

`dma_job_vseq`는 virtual sequence로 `env.vsqr`(`dma_vsqr`)에서 실행되고, 레지스터는 `regmodel.<reg>.write()/read()`(frontdoor)로,
메모리는 메모리 모델에 직접(백도어) 씁니다. 레지스터 테스트는 RAL 내장 sequence(`uvm_reg_hw_reset_seq`, `uvm_reg_bit_bash_seq`,
`uvm_reg_single_bit_bash_seq`)를 frontdoor로 돌립니다. sequence에는 자극과 `JOB_TIMEOUT`만 있고, 읽기값 비교는 `dma_predictor`가 합니다.

| 파일 | 하는 일 |
|---|---|
| `dma_job_vseq.svh` | job 하나를 끝까지 실행 (아래 4단계, 단계마다 노브로 켜고 끔) |
| `dma_pipeline_vseq.svh` | `dma_job_vseq`를 상속. idle 확인 없이 job을 잇달아 실행. 지금 job의 m00 R handshake 수가 `program_at_r`개가 되면 다음 job의 메모리와 레지스터를 쓰고, 지금 job이 done이 되면 바로 start. `value_at_r`로 다음 VALUE_TO_ADD를 쓰는 시점을 정함 |
| `dma_busy_reg_vseq.svh` | `dma_job_vseq`를 상속. 작업 중에 레지스터 10개(데이터 6개, GIE, IER, ISR, AP_CTRL)를 쓰고 모두 다시 읽음. 읽기값 비교는 `dma_predictor`가 함 |
| `dma_reset_vseq.svh` | 테스트 중간 리셋 한 번 (5절 "리셋") |
| `dma_reg_bitbash_vseq.svh` | RW 레지스터 8개: 1회차 0 배경 `uvm_reg_bit_bash_seq`(walking-1), 2회차 1을 모두 쓴 뒤 레지스터마다 `uvm_reg_single_bit_bash_seq`(walking-0), 끝나면 0. 읽기 1024회. AP_CTRL과 ISR은 `dma_reg_block::build`가 넣는 `NO_REG_BIT_BASH_TEST`로 제외 |

`dma_job_vseq` 순서:
1. **메모리 준비:**
   - src에 무작위 데이터를 채우고 스냅샷을 떠 둡니다.
   - dst 앞뒤에 guard 값 `A5`를 채웁니다.
   - dst 본체는 기대값의 비트 반전으로 미리 채웁니다(pre-poison).
2. **레지스터 설정과 시작:** `regmodel`로 레지스터를 씁니다. 순서는 `SW/mem_copy_test.c`와 같습니다. idle을 기다린 뒤 `ap_start`를 씁니다.
3. **완료 대기:** 시간 예산 안에서 기다립니다.
   - polling: done이 1이 될 때까지 AP_CTRL을 읽습니다.
   - IRQ: 인터럽트를 기다리고, ISR을 읽고, 3클럭 뒤 AP_CTRL을 읽습니다.
   - ISR[0], done, 인터럽트(GIE=0이면 0, ISR을 읽으면 내려감)는 `dma_predictor`가 비교합니다.
   - 예산 시간을 넘기면 `JOB_TIMEOUT` 에러입니다.
4. **idle 대기:** 다시 idle이 될 때까지 기다립니다. 메모리 검사와 `cg_job` 샘플링은 scoreboard가 마지막 B 뒤에 합니다.

`dma_job_vseq` 노브 (기본값에서는 단계로 나누기 전과 같은 접근을 같은 순서로 냅니다):

| 노브 | 뜻 |
|---|---|
| `do_prep`, `do_program`, `do_start`, `do_wait` | 위 1~3단계와 완료 대기를 각각 켜고 끔. 한 job을 여러 vseq에 나눠 실행할 수 있음 |
| `poison` | dst 본체 pre-poison. src와 dst가 겹치는(in-place) job이면 자동으로 꺼짐 |
| `wait_idle_before`, `wait_idle_after` | start 전, 완료 뒤에 idle polling |
| `gie`, `ier`, `start_value` | GIE, IER, AP_CTRL start에 쓸 값 (기본: job.mode, start 비트) |
| `done_wait` | `WAIT_BY_MODE`(기본), `POLL_DONE`, `IRQ`, `ISR_LOOP`(`n_irq`번), `WINDOW` |
| `ctrl_rd_delay` | 인터럽트 처리 뒤 AP_CTRL을 읽기까지 클럭 수 (기본 3) |
| `window_cycles`, `window_poll`, `window_min_ar` | `WINDOW`: 관찰 길이, AP_CTRL 읽기 간격, 창 안 AR 최소 수 (모자라면 `JOB_TIMEOUT`) |

알려진 한계: `done_wait=WINDOW`와 `wait_idle_after=1`을 같이 쓰면 끝나지 않은 DUT를 시간 한도 없이 polling합니다. 그래서 `dma_size_128mib_test`는 `wait_idle_after=0`입니다.

예전 RAL(2026-11-14 전)은 volatile 필드와 정의되지 않은 비트를 비교하지 않았습니다. 지금은 정의되지 않은 비트도 RO 필드로 두고, `dma_predictor`가 모든 읽기의 32비트 전체를 비교합니다.

## 4. Tests (`top/test/`, `unit/test/`)

**base test가 흐름을 정하고, 파생 테스트는 `configure()`에서 설정값만 바꿉니다.** 테스트 하나가 파일 하나입니다.

### Top: `dma_base_test.svh`
- **설정값:** `n_jobs`, `min_beats`, `max_beats`, `irq_pct`, `force_4k`, `cfg.slv_cfg.*`(backpressure)
- **`make_job(idx)`:** job마다 1MB 창을 따로 줘서 앞 job의 결과와 겹치지 않게 합니다. `force_4k`면 4KB 경계 바로 앞에서 시작하게 배치합니다. value는 0, 0xFF, 1, 무작위 중에서 고릅니다.
- **`run_job(j)`:** `dma_job_vseq`를 만들어 `env.vsqr`에서 실행합니다.
- **`run_phase`:** 리셋을 기다리고 `run_jobs()`를 부릅니다. 기본 동작은 `run_job(make_job(i))`를 n번 반복하는 것입니다.

| 파일 | 바꾸는 것 |
|---|---|
| `dma_checker_test.svh` | checker self-test. 결함 5종을 하나씩 일부러 넣고 예상 ID가 실제로 나오는지 확인 (표 아래 설명) |
| `dma_reg_reset_test.svh` | `run_jobs()`를 덮어써서 `uvm_reg_hw_reset_seq` 실행 (`seq.model = regmodel`, `seq.start(null)`) |
| `dma_reg_bitbash_test.svh` | `run_jobs()`를 덮어써서 `dma_reg_bitbash_vseq`를 `env.vsqr`에서 실행 |
| `dma_smoke_test.svh` | 32 beat job 1개 |
| `dma_short_job_test.svh` | 1~20 beat job 30개 |
| `dma_rand_test.svh` | 1~600 beat job 15개, IRQ 50%, 중간 정도 backpressure |
| `dma_4kb_cross_test.svh` | 모든 job이 4KB 경계를 넘도록 배치 |
| `dma_backpressure_test.svh` | 강한 backpressure (ready 20~30%, 지연 최대 40) |
| `dma_aw_backpressure_test.svh` | `aw_fixed_wait=40`, BUG-002 재현 (known_fail) |
| `dma_irq_test.svh` | 모든 job을 IRQ로 완료 |
| `dma_size_edge_test.svh` | 1/16/512 beat × polling/IRQ 조합을 직접 지정 (커버리지 메우기용) |
| `dma_long_job_test.svh` | 8192 beat(64KB) job 1개 |
| `dma_reset_test.svh` | 테스트 중간 리셋 3경우 (PASS). (1) idle에서 리셋 뒤 레지스터 10개를 리셋 값과 비교하고 job 실행 (2) 마지막 W 뒤 마지막 B 전에 리셋하고 버스가 조용한지 관찰 (3) ISR이 set되고 interrupt가 1인 채 리셋 |
| `dma_irq_ready_test.svh` | IER가 ready 또는 ready+done, GIE 0/1 조합 (PASS) |
| `dma_axil_timing_test.svh` | AXI-Lite master 타이밍 노브(`ctl_cfg`: AW/W 간격 최대 3, READY 지연 최대 4)를 켜고 리셋 값 읽기, 작업 중 레지스터 쓰기와 다시 읽기(`dma_busy_reg_vseq`, VALUE 하위 8비트 변경), 랜덤 job 8개(polling/IRQ). W 먼저, AW 먼저, 늦은 BREADY, 늦은 RREADY, 작업 중 쓰기를 버스로 확인하고 못 가면 `SCENARIO_MISS` (PASS) |
| `dma_busy_reg_write_test.svh` | 작업 중 레지스터 쓰기, 작업 중 VALUE_TO_ADD 변경(NOTE-002), idle 확인 없는 연속 job, in-place job (PASS) |

가설 테스트: 사양대로 기대를 검사하고 가설이 맞으면 FAIL합니다. 모두 `known_fail`로 등록돼 XFAIL로 보고됩니다. 가설 판정과 버그 설명은 [BUGS.md](../verif/BUGS.md), 가설 목록은 `verif/plan.toml`에 있고, 여기에는 테스트의 자극만 적습니다. 노린 상태에 실제로 갔는지는 버스 관찰로 확인하고, 못 갔으면 `SCENARIO_MISS` 에러입니다.

| 파일 | 가설 | 자극 |
|---|---|---|
| `dma_start_busy_test.svh` | BUG-005 | 작업 중 start를 쓰고, 이어서 idle을 확인한 start (`a_ap_idle_leave`가 어김) |
| `dma_auto_restart_test.svh` | BUG-005 | `AP_CTRL=0x81`, 반복 횟수와 끄기 |
| `dma_reset_mid_job_test.svh` | BUG-006 | W를 막아 파이프라인을 채운 뒤 리셋하고 start 없이 관찰, 이어서 job 2개 |
| `dma_size_128mib_test.svh` | BUG-007 | bytes=0x0800_0040, 0x0800_0000 (`WINDOW`로 관찰) |
| `dma_aw_wait_after_job_test.svh` | BUG-003 | 앞 job 이력을 만든 뒤 AW 대기(`aw_fixed_wait`)를 실행 중에 바꿔 W가 AW보다 먼저 오게 함 |
| `dma_slow_b_test.svh` | BUG-004 | B 지연 0..60 (`max_b_latency`)으로 미해결 burst를 쌓음 |

### Top: checker self-test (`dma_checker_test.svh`, `dma_error_catcher.svh`)

주입 노브는 기본이 0이라 다른 테스트에는 영향이 없습니다. 주입 창을 차례로 열고, 창마다 예상 ID가 나와야 합니다.

| 주입 | 노브 | 예상 ID |
|---|---|---|
| 리셋 직후 VALUE_TO_ADD 읽기 관찰값 bit31 | `axil_monitor` `inj_rd_*` | `REG_RESET` |
| R beat 데이터 비트 하나 | `axi4_slave_cfg` `inj_r_flip` | `SB_WDATA`, `SB_DATA` |
| R beat 하나를 같은 burst 안 이웃 8바이트에서 읽음 | `inj_r_addr` | `SB_WDATA`, `SB_DATA` |
| 마지막 쓰기 burst를 +8바이트 밀어 씀 | `inj_w_shift_end` | `SB_DATA`, `SB_OVERRUN` |
| 레지스터를 쓴 뒤 첫 AP_CTRL 읽기(start 전 idle 대기) 관찰값 bit31 | `axil_monitor` `inj_rd_*` | `REG_BITBASH` |

- `dma_error_catcher`(`uvm_report_catcher`)는 열린 창의 예상 ID만 UVM_INFO로 낮춥니다. 그 밖의 오류는 그대로여서 테스트가 FAIL합니다.
- 끝에 예상 ID가 한 번도 나오지 않았으면 `SELFTEST_MISS` 에러입니다.
- `+SELFTEST_NO_INJECT`: 창은 열고 주입은 하지 않습니다. `SELFTEST_MISS`로 FAIL해야 하는 음성 대조이고, 회귀에는 넣지 않습니다.

### Unit: `unit_base_test.svh`
- **DUT 종류:** TB top이 config_db에 넣어 준 `dut_kind`로 정합니다. adder면 `lane_bw`도 같이 받습니다.
- **`run_phase`:** `stream_rand_seq`를 시작합니다. 그다음 모든 beat이 출력될 때까지 기다리고(시간 예산 안에서), 200ns를 더 기다려 남는 beat가 나오는지 봅니다.
- **파생 테스트:**
  - `unit_smoke_test`
  - `unit_post_reset_test`: BUG-001 재현용
  - `unit_single_beat_test`: 리셋이 충분히 지난 뒤 beat 1개만 보냄 (skid TB에만 등록)
  - `unit_rand_test`
  - `unit_backpressure_test`
  - `unit_sparse_input_test`
  - `unit_fixed_value_test`

`+N_ITEMS`(unit)와 `+N_JOBS`(top) plusarg로 수량을 바꿀 수 있습니다.

## 5. TB top (`top/tb_dma.sv`, `unit/tb_*.sv`)

- **`tb_dma.sv`:**
  - 100MHz 클럭을 만들고, 전원 리셋(20사이클)은 `dma_reset_if`의 `power_on()`으로 겁니다.
  - `axil_if ctl`과 `axi4_if mem`을 DUT에 연결합니다.
  - `uvm_test_top.env.axil_agt`와 `uvm_test_top.env.mem_agt`에 vif를, `uvm_test_top.env.vsqr`에 리셋 interface를 넣습니다.
  - 50ms 전역 타임아웃을 걸고 `run_test()`를 부릅니다.
- **`dma_reset_if.sv`:** active-low `rst_n` 하나를 가진 interface입니다. `power_on(n)`(전원 리셋)과 `pulse(n)`(테스트 중간 리셋)이 같은 신호를 구동하고, DUT와 TB 모니터가 이 신호를 봅니다.
- **`dma_ap_ctrl_sva.sv`:** ap_ctrl_hs assertion 모듈과 `dma_ip_top`에 거는 `bind`입니다 (2절 `APCTRL_SVA`). 기본 `top.f` 순서에서 패키지 뒤, `tb_dma.sv` 앞입니다.
- **unit TB:** 공통 부분은 `tb_unit_common.svh`가 담당합니다. TB 파일 3개(`tb_fifo`, `tb_skid`, `tb_adder`)와 define 조합으로 unit TB 5종이 나옵니다.
  - `fifo` / `fifo_d4`: 깊이 64 / 4
  - `skid`
  - `adder` / `adder8`: lane 32비트 / 8비트

### 리셋 (테스트 중간 리셋)

흐름은 [FLOW.md](FLOW.md) 3절에 한 줄로 적고, 구성 요소별 동작은 여기가 원본입니다.

```
 test ─ dma_reset_vseq (env.vsqr) ─ lock(axil_sqr) ─ 진행 중 AXI-Lite 끝나기를 기다림 ─ rst_vif.pulse(n) ─ unlock
                                                          │
 rst_n=0 ──┬─ DUT
           ├─ axi4_slave_driver   : ready/valid 0, burst와 큐 버림 (메모리와 카운터 유지), 해제 뒤 재시작
           ├─ axi4_slave_monitor  : 리셋 에지의 handshake 무시, W/AW 짝 맞춤을 처음부터
           ├─ axil_monitor        : 리셋 에지의 handshake 무시, 짝이 안 맞은 큐 비움
           ├─ dma_predictor       : 실행 중 job 중단 (job_ap로 같은 handle 재전송), 모델과 mirror를 리셋 값으로
           └─ dma_scoreboard      : 중단된 job은 정보(SB_JOB ABORTED). 리셋 뒤 job 없는 활동은 SB_NO_JOB_BUS
```

- **`dma_reset_vseq`:** `axil_sqr`를 lock하고, master 쪽 VALID/READY가 연속으로 비는 것을 본 뒤 리셋을 겁니다. 그래도 끝나지 않으면 `RESET_BUSY`입니다. 리셋 중에 AXI-Lite VALID가 1이 되면 `RESET_BUSY`입니다. "접근 중에는 master 쪽 신호 하나가 늘 1"이라는 전제는 AXI-Lite 타이밍 노브(`ctl_cfg`, `axil_cfg`)가 0일 때만 맞으므로, 노브가 0이 아니면 시작하지 않고 `RESET_CFG` fatal입니다.
- **`n_cycles` 최소 2:** TB 쪽은 해제 에지를 이미 리셋 밖으로 읽어(전원 리셋 때와 같음) n-1 에지만 리셋으로 봅니다. 2 미만이면 `RESET_CFG` fatal입니다. 자세한 이유는 `dma_reset_if.sv` 머리 주석에 있습니다.
- **같은 job handle 재전송:** scoreboard가 `t_abort`가 있는 handle은 중단으로, 없는 handle이 다시 오면 `SB_DUP_JOB`으로 구분합니다.

## 새 테스트를 추가하려면

1. `verif/<unit|top>/test/<test_name>.svh`를 만듭니다. 클래스는 하나만 넣습니다.
2. 같은 디렉터리의 `*_test_pkg.sv`에 `` `include "<test_name>.svh" ``를 추가합니다.
3. `verif/sim_cfg.json`의 `tests` 목록에 넣고, `verif/plan.toml`의 기능에 테스트를 넣은 뒤 `python scripts/plan_check.py --write`로 vplan.md를 다시 만듭니다.
4. lint → seed 3개 이상 실행 → 영향받는 suite 회귀 테스트 순서로 확인합니다.
