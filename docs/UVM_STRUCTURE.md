# UVM 코드 구조

전체 저장소 구성은 [ARCHITECTURE.md](ARCHITECTURE.md), 실행 흐름은 [FLOW.md](FLOW.md)를 참고하세요.

## 규칙

- **파일 하나 = 클래스 하나, 파일 이름 = 클래스 이름입니다.** 예: `dma_scoreboard` → `dma_scoreboard.sv`.
  driver는 driver 파일에만, scoreboard는 scoreboard 파일에만 있습니다.
- **`*_pkg.sv`는 목차입니다.** import, 패키지 공용 typedef/상수, 그리고 클래스 파일을 `` `include ``하는 줄만 담습니다.
  filelist에는 패키지 파일만 적고, 패키지 디렉터리마다 `+incdir+`를 둡니다.
- **RAL을 쓰지 않습니다.** 레지스터는 `axil_base_seq`의 `write_reg()`/`read_reg()`와
  `dma_reg_map.sv`의 주소 상수로 직접 읽고 씁니다.
- **자극(stimulus)은 시퀀스에 둡니다.** env는 컴포넌트를 만들고 연결하는 일만 합니다.

## 디렉터리

```
verif/
├─ agents/
│  ├─ vr_agent/            valid/ready 스트림 (unit TB)
│  │    vr_if.sv  vr_pkg.sv
│  │    vr_item.sv  vr_cfg.sv  vr_sequencer.sv
│  │    vr_master_driver.sv  vr_slave_driver.sv  vr_monitor.sv  vr_agent.sv
│  │    vr_stream_seq.sv
│  ├─ axil_agent/          AXI4-Lite 마스터 (top TB, DUT 제어 레지스터)
│  │    axil_if.sv  axil_pkg.sv
│  │    axil_item.sv  axil_sequencer.sv  axil_driver.sv  axil_agent.sv
│  │    axil_base_seq.sv   ← write_reg / read_reg
│  └─ axi4_slv_agent/      AXI4 슬레이브 + 메모리 모델 (top TB, DUT m00)
│       axi4_if.sv  axi4_slv_pkg.sv
│       axi4_slv_cfg.sv  axi4_mem.sv  axi4_burst.sv
│       axi4_slv_driver.sv  axi4_slv_monitor.sv  axi4_slv_agent.sv
├─ env/
│  ├─ unit/   unit_env_pkg.sv  unit_env_cfg.sv  unit_scoreboard.sv  unit_coverage.sv  unit_env.sv
│  └─ top/    dma_env_pkg.sv  dma_reg_map.sv  dma_job.sv  dma_env_cfg.sv
│             dma_scoreboard.sv  dma_coverage.sv  dma_env.sv
├─ sequences/
│  └─ top/    dma_seq_pkg.sv  dma_job_seq.sv  dma_reg_reset_seq.sv  dma_reg_bitbash_seq.sv
├─ tests/
│  ├─ unit/   unit_test_pkg.sv  unit_base_test.sv  unit_*_test.sv (6개)
│  └─ top/    dma_test_pkg.sv   dma_base_test.sv   dma_*_test.sv (11개)
└─ tb/        tb_top.sv, tb_fifo.sv, tb_skid.sv, tb_adder.sv, tb_unit_common.svh
```

패키지 의존은 한 방향입니다.

```
top : axil_pkg, axi4_slv_pkg → dma_env_pkg → dma_seq_pkg → dma_test_pkg → tb_top
unit: vr_pkg → unit_env_pkg → unit_test_pkg → tb_fifo / tb_skid / tb_adder
```

---

## 1. Agent

### `vr_agent`: 범용 valid/ready 에이전트 (unit TB)

| 파일 | 역할 |
|---|---|
| `vr_item.sv` | `data[63:0]`, `side[31:0]`(adder의 더할 값), `delay`(valid 전 쉬는 사이클 수) |
| `vr_cfg.sv` | `mode`(MASTER/SLAVE/PASSIVE), `post_reset_idle`, slave backpressure 설정값(`ready_pct`, `stall_pct`, `max_stall`) |
| `vr_sequencer.sv` | `vr_item` sequencer (master 모드에서만 생성) |
| `vr_master_driver.sv` | sequence에서 item을 받아 valid/data/side를 올리고 ready가 올 때까지 유지 |
| `vr_slave_driver.sv` | sequencer 없이 혼자 무작위 ready를 냄. 가끔 길게 멈춤(stall) |
| `vr_monitor.sv` | `valid && ready`인 사이클마다 item을 만들어 analysis port로 보냄 |
| `vr_agent.sv` | `cfg.mode`에 따라 위 컴포넌트를 골라 만들고 연결 |
| `vr_stream_seq.sv` | item을 n개 생성. 코너값(0, 전부 1, MSB 등)은 절차적으로 섞음 (XSim `dist` 버그 회피) |

하나의 에이전트를 모드만 바꿔서 입력 쪽(MASTER)과 출력 쪽(SLAVE)에 모두 씁니다.

### `axil_agent`: AXI4-Lite 마스터 (top TB)

| 파일 | 역할 |
|---|---|
| `axil_item.sv` | 읽기 또는 쓰기 한 건 (`write`, `addr`, `data`, `resp`) |
| `axil_sequencer.sv` | `axil_item` sequencer |
| `axil_driver.sv` | 쓰기: AW와 W를 동시에 내고 각각 handshake 후 B를 받음. 읽기: AR 후 R을 받아 item에 `data`/`resp`를 채움 |
| `axil_agent.sv` | sequencer + driver |
| `axil_base_seq.sv` | 레지스터 시퀀스의 기본 클래스. `write_reg(addr, data)`, `read_reg(addr, data)`. 응답이 OKAY가 아니면 `UVM_ERROR` |

### `axi4_slv_agent`: 반응형 AXI4 슬레이브 + 메모리 모델 (top TB, DDR 대신)

| 파일 | 역할 |
|---|---|
| `axi4_slv_cfg.sv` | 채널별 ready 확률, `aw_fixed_wait`(BUG-002 재현용), R/B 지연, R 사이 쉬는 사이클 확률 |
| `axi4_mem.sv` | `bit[7:0] m[bit[31:0]]` 희소 바이트 메모리. `wr8`/`rd8`/`has`/`rd64`/`wr64` |
| `axi4_burst.sv` | AR/AW 한 건 (addr, len, size, burst) |
| `axi4_slv_driver.sv` | 슬레이브 쪽 신호 구동. 아래 6개 task를 `fork`로 동시에 실행 |
| `axi4_slv_monitor.sv` | AR/AW handshake를 관찰해 `axi4_burst`로 만들어 `ar_ap`/`aw_ap`로 보내고, burst 규칙을 검사 |
| `axi4_slv_agent.sv` | cfg + mem + driver + monitor. `mem`과 `ar_ap`/`aw_ap`를 env에 노출 |

```
 driver:  ar_channel ─→ ar_q ─→ r_channel        (요청 순서대로, 첫 beat 지연과 중간 쉬는 사이클을 무작위로)
          aw_channel ─→ aw_q ─┐
          w_channel  ─→ w_q  ─┴→ write_engine ─→ b_q ─→ b_channel
 monitor: AR/AW handshake ─→ check_burst ─→ ar_ap / aw_ap
```

- **monitor 검사:** burst마다 INCR인지, 크기가 8바이트인지, 8바이트 정렬인지, 16 beat 이하인지, 4KB 경계를 넘지 않는지 확인합니다.
- **driver 검사:**
  - 마지막 beat에서만 WLAST가 오는지
  - 초기화하지 않은 메모리를 읽지 않는지
  - 시뮬레이션이 끝날 때 처리하지 못한 AR/AW/W/B가 남지 않았는지
- **W가 AW보다 먼저 와도 받습니다.** AXI 규칙상 합법이기 때문입니다. `write_engine`이 나중에 AW와 W beat를 짝짓습니다. BUG-002의 WLAST 오류가 바로 여기서 잡혔습니다.

## 2. Env

### Top (`env/top/`)

```
 axil_agt ── write_reg/read_reg ──→ DUT 제어 레지스터
 mem_agt  ── ar_ap/aw_ap ──┬→ dma_scoreboard (mem 공유)
                           └→ dma_coverage
```

| 파일 | 역할 |
|---|---|
| `dma_reg_map.sv` | 레지스터 주소(`ADDR_AP_CTRL` … `ADDR_VALUE_TO_ADD`)와 AP_CTRL/ISR 비트 위치 상수 |
| `dma_job.sv` | DMA 실행 한 번: `src`, `dst`, `bytes`, `value`, `mode`(polling 또는 IRQ) |
| `dma_env_cfg.sv` | 슬레이브 cfg, 클럭 주기(시간 예산 계산용) |
| `dma_scoreboard.sv` | job 단위 검사 (아래) |
| `dma_coverage.sv` | `cg_job`, `cg_burst` |
| `dma_env.sv` | `axil_agt`, `mem_agt`, `sb`, `cov` 생성과 연결. 시퀀스가 쓰는 `ctl_vif`(클럭, 인터럽트)와 `clocks(n)` |

레지스터 맵:

| 오프셋 | 상수 | 비고 |
|---|---|---|
| 0x00 | `ADDR_AP_CTRL` | start[0], done[1](COR), idle[2], ready[3](COR), auto_restart[7], interrupt[9] |
| 0x04 / 0x08 / 0x0C | `ADDR_GIE` / `ADDR_IER` / `ADDR_ISR` | ISR은 읽으면 지워짐(COR) |
| 0x10 / 0x14 | `ADDR_RDMA_TRANSFER_BYTE` / `ADDR_RDMA_MEM_PTR` | |
| 0x18 / 0x1C | `ADDR_WDMA_TRANSFER_BYTE` / `ADDR_WDMA_MEM_PTR` | |
| 0x20 / 0x24 | `ADDR_AXI00_PTR0` / `ADDR_VALUE_TO_ADD` | |

`dma_scoreboard` 검사 항목:
- **데이터:** 모든 dst 바이트가 `src + value[7:0]`인지
- **넘침:** dst 앞뒤 64바이트 guard 값이 바뀌지 않았는지
- **원본:** src가 바뀌지 않았는지
- **주소 범위:** burst가 src/dst 창 안에 있는지
- **수량:** AR beat 총수와 AW beat 총수가 각각 job의 beat 수와 같은지
- **job 수:** job이 하나도 검사되지 않으면 에러입니다. 레지스터 전용 테스트는 `expect_jobs = 0`으로 끕니다.

`dma_coverage`:
- **`cg_job`:**
  - 크기 구간(1, 2~15, 16, 17~511, 512, 513 이상)
  - value 코너, value 상위 비트가 무시되는지
  - 완료 모드
  - src/dst 4KB 경계 통과 여부
  - 크기 × 모드 교차
- **`cg_burst`:** 방향 × 길이, 방향 × "4KB 경계에서 잘린 burst"

### Unit (`env/unit/`)

```
 in_agt (MASTER) → DUT → out_agt (SLAVE, 무작위 ready)
      └─ ap ─→ sb.in_imp / cov        out_agt.ap ─→ sb.out_imp
```

| 파일 | 역할 |
|---|---|
| `unit_env_cfg.sv` | `model`(`MODEL_PASS`: FIFO/skid, `MODEL_ADD`: adder), `lane_bw`, in/out agent cfg |
| `unit_scoreboard.sv` | 입력이 오면 기대값을 큐에 넣고, 출력이 오면 순서대로 비교. 끝날 때 큐에 남은 것이 있으면 에러 |
| `unit_coverage.sv` | `cg_beat`(데이터/side 코너, lane별 carry), `cg_cycle`(매 사이클 {valid, ready}, 연속 전송, stall 해제) |
| `unit_env.sv` | 에이전트 2개 + scoreboard + coverage 생성과 연결 |

## 3. Sequences (`sequences/top/`)

세 시퀀스 모두 `axil_base_seq`를 상속하고, `env.axil_agt.sqr`에서 실행됩니다.

| 파일 | 하는 일 |
|---|---|
| `dma_job_seq.sv` | job 하나를 끝까지 실행 (아래 4단계) |
| `dma_reg_reset_seq.sv` | 리셋 직후 레지스터 10개를 읽어 32비트 전체를 리셋 값과 비교 (AP_CTRL은 idle=1만, 나머지는 0) |
| `dma_reg_bitbash_seq.sv` | RW 레지스터 8개의 구현된 비트마다 walking-1과 walking-0을 쓰고 읽어 32비트 전체 비교 (390회). AP_CTRL과 ISR은 제외 |

`dma_job_seq` 순서:
1. **메모리 준비:**
   - src에 무작위 데이터를 채우고 스냅샷을 떠 둡니다.
   - dst 앞뒤에 guard 값 `A5`를 채웁니다.
   - dst 본체는 기대값의 비트 반전으로 미리 채웁니다(pre-poison).
2. **레지스터 설정과 시작:** `write_reg`로 레지스터를 씁니다. 순서는 `SW/mem_copy_test.c`와 같습니다. idle을 기다린 뒤 `ap_start`를 씁니다.
3. **완료 대기:** 시간 예산 안에서 기다립니다.
   - polling: AP_CTRL.done을 읽고, 인터럽트가 0인지 확인합니다.
   - IRQ: 인터럽트를 기다리고, ISR을 읽은 뒤 인터럽트가 내려가는지 확인합니다.
   - 예산 시간을 넘기면 `JOB_TIMEOUT` 에러입니다.
4. **검사:** `sb.check_job()`과 `cov.sample_job()`을 부르고, 다시 idle이 될 때까지 기다립니다.

기존 RAL 시퀀스(`uvm_reg_hw_reset_seq`, `uvm_reg_bit_bash_seq`)보다 검사가 엄격합니다. RAL은 volatile 필드와 정의되지 않은 비트를 비교하지 않았지만, 지금은 32비트 전체를 비교합니다.

## 4. Tests (`tests/`)

**base test가 흐름을 정하고, 파생 테스트는 `configure()`에서 설정값만 바꿉니다.** 테스트 하나가 파일 하나입니다.

### Top: `dma_base_test.sv`
- **설정값:** `n_jobs`, `min_beats`, `max_beats`, `irq_pct`, `force_4k`, `cfg.slv_cfg.*`(backpressure)
- **`make_job(idx)`:** job마다 1MB 창을 따로 줘서 앞 job의 결과와 겹치지 않게 합니다. `force_4k`면 4KB 경계 바로 앞에서 시작하게 배치합니다. value는 0, 0xFF, 1, 무작위 중에서 고릅니다.
- **`run_job(j)`:** `dma_job_seq`를 만들어 `env.axil_agt.sqr`에서 실행합니다.
- **`run_phase`:** 리셋을 기다리고 `run_jobs()`를 부릅니다. 기본 동작은 `run_job(make_job(i))`를 n번 반복하는 것입니다.

| 파일 | 바꾸는 것 |
|---|---|
| `dma_reg_reset_test.sv` | `run_jobs()`를 덮어써서 `dma_reg_reset_seq` 실행 |
| `dma_reg_bitbash_test.sv` | `run_jobs()`를 덮어써서 `dma_reg_bitbash_seq` 실행 |
| `dma_smoke_test.sv` | 32 beat job 1개 |
| `dma_small_test.sv` | 1~20 beat job 30개 |
| `dma_rand_test.sv` | 1~600 beat job 15개, IRQ 50%, 중간 정도 backpressure |
| `dma_4kb_test.sv` | 모든 job이 4KB 경계를 넘도록 배치 |
| `dma_backpressure_test.sv` | 강한 backpressure (ready 20~30%, 지연 최대 40) |
| `dma_aw_backpressure_test.sv` | `aw_fixed_wait=40`, BUG-002 재현 (known_fail) |
| `dma_irq_test.sv` | 모든 job을 IRQ로 완료 |
| `dma_size_edge_test.sv` | 1/16/512 beat × polling/IRQ 조합을 직접 지정 (커버리지 메우기용) |
| `dma_large_test.sv` | 8192 beat(64KB) job 1개 |

### Unit: `unit_base_test.sv`
- **DUT 종류:** TB top이 config_db에 넣어 준 `dut_kind`로 정합니다. adder면 `lane_bw`도 같이 받습니다.
- **`run_phase`:** `vr_stream_seq`를 시작합니다. 그다음 모든 beat이 출력될 때까지 기다리고(시간 예산 안에서), 200ns를 더 기다려 남는 beat가 나오는지 봅니다.
- **파생 테스트:**
  - `unit_smoke_test`
  - `unit_post_reset_test`: BUG-001 재현용
  - `unit_rand_test`
  - `unit_backpressure_test`
  - `unit_trickle_test`
  - `unit_fixed_side_test`

`+N_ITEMS`(unit)와 `+N_JOBS`(top) plusarg로 수량을 바꿀 수 있습니다.

## 5. TB top (`tb/`)

- **`tb_top.sv`:**
  - 100MHz 클럭과 리셋(20사이클)을 만듭니다.
  - `axil_if ctl`과 `axi4_if mem`을 DUT에 연결합니다.
  - `uvm_test_top.env.axil_agt`와 `uvm_test_top.env.mem_agt`에 vif를 넣습니다.
  - 50ms 전역 타임아웃을 걸고 `run_test()`를 부릅니다.
- **unit TB:** 공통 부분은 `tb_unit_common.svh`가 담당합니다. TB 파일 3개(`tb_fifo`, `tb_skid`, `tb_adder`)와 define 조합으로 unit TB 5종이 나옵니다.
  - `fifo` / `fifo_d4`: 깊이 64 / 4
  - `skid`
  - `adder` / `adder8`: lane 32비트 / 8비트

## 새 테스트를 추가하려면

1. `verif/tests/<unit|top>/<test_name>.sv`를 만듭니다. 클래스는 하나만 넣습니다.
2. 같은 디렉터리의 `*_test_pkg.sv`에 `` `include "<test_name>.sv" ``를 추가합니다.
3. `verif/sim_cfg.json`의 `tests` 목록과 `verif/vplan/vplan.md`에 추가합니다.
4. lint → seed 3개 이상 실행 → 영향받는 suite 회귀 테스트 순서로 확인합니다.
