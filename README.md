# dma-uvm-verif

간단한 AXI DMA IP(`dma_ip_top`: RDMA → FIFO → adder → FIFO → WDMA, AXI4-Lite 제어, AXI4 master)를
Vivado 2022.2 XSim에서 검증하는 UVM 환경, CI/CD, 에이전트 도구입니다. 기본 대상은 Zybo Z7-20
(xc7z020clg400-1)이고, 실보드 시험은 Zybo Z7-10(xc7z010clg400-1)에서 했습니다.

**포트폴리오 페이지:** https://socdesignasic.github.io/dma-uvm-verif/

> **DUT RTL은 들어 있지 않습니다.** 이 저장소에는 검증 코드만 있습니다. 실행하기 전에
> 다음을 추가하세요 (모두 이 저장소의 git에서 무시됨):
> - `HW/`: DUT RTL. 테스트벤치는 `verif/rtl.f`와 unit filelist(`verif/unit/*.f`)에 적힌 파일과 모듈 이름을
>   기대합니다 (top 모듈 `dma_ip_top`)
> - `uvm_reference/`: 참고용 UVM 예제 (`ref_adder*` 테스트벤치만 사용)
> - `ci/vivado/ip/dma_ip_top/`: IP 패키징 메타데이터 (`component.xml`, `xgui/`).
>   `scripts/fpga.py system`(비트스트림 빌드)에만 필요
> - `SW/`: 참조용 보드 예제 (쓰지 않음. C 보드 시험은 `fw/`에 새로 작성)

## 지금 상태 (2026-11-21)

TB를 재설계(2026-11-19~21)한 뒤의 상태입니다. 상세는 [verif/SIGNOFF.md](verif/SIGNOFF.md),
[verif/BUGS.md](verif/BUGS.md), [verif/vplan/vplan.md](verif/vplan/vplan.md)(원본 `verif/plan.toml`)에 있습니다.

**TB 재설계 요약** (구조는 [docs/UVM_STRUCTURE.md](docs/UVM_STRUCTURE.md)):
- RAL 레지스터 모델: 정의되지 않은 비트도 RO 필드로 모델링해 32비트 전체를 frontdoor로 읽고 씁니다.
- predictor: 버스 handshake만 입력으로 RTL 상태를 매 클럭 따라가는 사이클 모델입니다. 모든 AXI-Lite 읽기 값과
  interrupt 핀을 비교합니다.
- scoreboard: 모니터가 본 것(burst 목록, W beat, 결과 메모리)으로만 판정합니다.
- checker self-test: 결함 5종을 일부러 넣어 검사가 실제로 오류를 내는지 확인합니다 (`dma_checker_test`).
- SVA: ap_ctrl_hs 규칙 7개를 `bind`로 붙입니다 (RTL 수정 없음).
- 테스트 중간 리셋: predictor, scoreboard, slave 모델이 리셋을 따라갑니다.

**결과:**
- 검사(uvm_error, SVA) 123개를 기준선(`verif/check_baseline.json`)으로 관리합니다. 줄거나 억제가 늘면 실패합니다.
- RTL 버그 7건: BUG-001 won't fix, BUG-002~007 open. 설계 노트 3건 (NOTE-001~003). RTL은 고치지 않았습니다.
- 가설 7개(H1~H7)를 모두 시뮬레이션으로 판정했습니다. 6개는 BUG-003~007로, 1개는 NOTE-002로 정리했습니다.
- full 회귀(seed 5): 260회, fail 0, XFAIL 50 (known_fail 10개 × seed 5). 6개 TB 기능 커버리지 모두 100%.
- release 판정 (2026-11-21): **PASS, 조건부 출시.** BUG-002~007이 open이고 waiver는 RTL 담당자 결정 대기입니다.
  Zybo Z7-10 보드 시험을 다시 해서 JTAG 7/7, ARM C 7/7 PASS입니다.

**출시 노트 조건:**
- AWREADY나 B 응답을 늦추는 interconnect에서 쓰지 않습니다 (BUG-002, BUG-003, BUG-004).
- start는 idle 확인 뒤 한 번만 쓰고, auto_restart는 쓰지 않습니다 (BUG-005).
- 작업 도중 PL 리셋을 했다면 그 뒤 작업 결과를 신뢰하지 않습니다 (BUG-006).
- transfer_byte는 128MiB 미만입니다 (BUG-007).

BUG-001(won't fix)과 NOTE-001(타이밍 여유)의 조건은 `verif/SIGNOFF.md`의 2026-11-18 판정과 같습니다.

## 구성

| 경로 | 내용 |
|---|---|
| `verif/vip/` | 재사용 VIP (DUT를 모름): `stream/` (valid/ready), `axil/` (AXI4-Lite master, RAL adapter), `axi4_slave/` (driver, monitor, 메모리 모델) |
| `verif/{top,unit,ref_adder,selftest}/` | 테스트벤치 폴더. top과 unit은 안에 `<이름>.f`, `tb_*.sv`, 역할 폴더 `env/`, `model/`, `scoreboard/`, `coverage/`, `seq/`, `test/`를 둡니다 (unit은 VIP의 sequence를 써서 `seq/` 없음). 클래스 파일은 `.svh`, `verif/rtl.f`는 RTL 파일 목록 |
| `verif/` 문서와 목록 | 테스트 목록(`sim_cfg.json`), 검증 계획 원본(`plan.toml`)과 생성물(`vplan/vplan.md`), 검사 기준선(`check_baseline.json`), 버그 목록(`BUGS.md`), sign-off 기준(`SIGNOFF.md`) |
| `scripts/` | `sim.py` (lint/실행/커버리지), `regress.py` (병렬 회귀, `--plan`), `ml_regress.py` (커버리지 모델 학습과 회귀 계획), `signoff.py` (sign-off 판정), `gate.py`, `plan_check.py`, `check_inventory.py`, `check_docs.py` (단계 판정과 정적 검사), `fpga.py` (OOC 타이밍, 비트스트림 + XSA), `board.py` / `board_c.py` (보드 시험) |
| `fw/dma_board_test/` | Cortex-A9 bare-metal C 보드 시험 프로그램 (Vitis standalone BSP) |
| `Jenkinsfile`, `ci/` | 로컬 Jenkins (Configuration as Code), Vivado 블록 디자인과 IP 패키징, xsdb 보드 시험(`ci/vivado/board_*.tcl`), Vitis 빌드(`ci/vitis/`) 스크립트 |
| `mcp/` | 시뮬레이션 흐름을 에이전트에 제공하는 MCP 서버 |
| `.claude/`, `CLAUDE.md` | 에이전트 규칙, 서브에이전트 7개, 스킬 7개, `HW/`를 읽기 전용으로 지키는 hook |
| `docs/` | 저장소 구성, 흐름, UVM 코드 구조, 검증·CI/CD 결과 보고서 |

## 빠른 시작 (`HW/`에 RTL을 넣은 뒤)

```bash
python scripts/sim.py list
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top
```

## Sign-off

"검증이 끝났다"는 `verif/SIGNOFF.md`의 기준 S1~S11로 정하고, `scripts/signoff.py`가 결과 파일로 판정합니다.
Jenkins는 모든 빌드 끝에 Sign-off 단계를 돌려 `out/signoff/signoff.md`를 남기고, 기준을 못 채우면 UNSTABLE로 표시합니다.
기준 표와 수준별 적용은 `verif/SIGNOFF.md`가 원본입니다.

| 수준 | 언제 | 보는 기준 |
|---|---|---|
| `smoke` | push마다 | 바뀐 코드가 기존 기능과 커버리지를 깨지 않음: 회귀 fail 0, XFAIL은 승인된 known_fail만, 모든 테스트 실행(seed 1개), 커버리지 100%, ML 계획 목표 bin 전부, OOC 타이밍, vplan 완결성, 근거 출처, 승인된 RTL 해시 |
| `nightly` | 매일 02:00 | smoke 기준(ML 계획 제외) + 테스트당 seed 5개 + 시스템 빌드 타이밍과 비트스트림 |
| `release` | 출시 판정 (수동) | nightly + 실보드 시험(JTAG, ARM C) |

- **S10 (근거 출처):** 근거 파일이 모두 같은 커밋에서 나와야 합니다. 출처가 없는 결과는 FAIL입니다.
  release는 수정 없는 checkout이어야 하고, 보드에 올린 XSA는 승인된 RTL로 만든 시스템 빌드여야 합니다.
- **S11 (승인된 RTL 해시):** `HW/` 내용 해시가 `plan.toml`의 승인된 값과 같아야 합니다. RTL이 바뀌면 사람이 확인하고 값을 갱신합니다.
- **waiver = known_fail 승인:** RTL 버그 확정 → `BUGS.md` 기록 → RTL 담당자가 상태 결정 → 재현 테스트를 `known_fail`로 등록.
  RTL이 고쳐지면 XPASS로 빌드가 실패해 수정이 조용히 지나가지 않습니다.
- 판정을 처음 돌렸을 때 S9가 vplan에 빠진 테스트 2개(`dma_smoke_test`, 지금의 `dma_short_job_test`)를 찾아 고쳤습니다.

```bash
python scripts/signoff.py --level smoke      # smoke, nightly, release
```

## ML 회귀 최적화

회귀를 얼마나 돌려야 커버리지가 닫히는지를 데이터로 정합니다 (`scripts/ml_regress.py`).

1. **데이터**: 회귀의 실행마다 기능 커버리지 DB를 `xcrg`로 풀어 bin별 적중 여부를 수집합니다.
2. **모델**: (테스트, bin)마다 seed 하나로 그 bin을 칠 확률 p를 Beta-Bernoulli 사후 평균으로 추정합니다.
3. **계획**: bin을 놓칠 확률 `prod_t (1 - p_tb)^n_t`의 합이 `1 - target` 아래가 될 때까지, 실행 1초당 기대
   커버리지 증가가 가장 큰 테스트에 seed를 하나씩 더합니다 (greedy). 기본으로 모든 테스트를 1회 이상 넣어
   커버리지에 안 잡히는 검사(레지스터, 알려진 버그 재현)도 계속 돌립니다.
4. **검증**: 테스트마다 seed를 반으로 나눠 절반으로 학습하고, 학습에 안 쓴 절반에서 계획대로 실행을 뽑아
   모든 bin을 채우는 비율을 셉니다 (분할 20번 x 추출 200번).

```bash
python scripts/regress.py --suite all --seeds 20 --jobs 6 --name ml_data     # 학습 데이터 (820회)
python scripts/ml_regress.py extract --from out/regress/ml_data/summary.json
python scripts/ml_regress.py analyze --save-plan verif/regress_plan.json    # 계획 (CI smoke가 사용), out/ml/report.md
python scripts/regress.py --plan verif/regress_plan.json                    # 계획대로 회귀
python scripts/ml_regress.py check --summary out/regress/plan/summary.json  # 목표 bin을 모두 채웠는지
```

결과 (2026-11-17, 실행 820회로 학습, 6개 TB의 목표 bin 183개):

| 방식 | 실행 수 | 모든 TB 100% 도달 비율 (학습에 안 쓴 seed) |
|---|---|---|
| nightly full (테스트당 seed 5개) | 205 | 100.0% |
| **ML 계획** (모든 테스트 1회 이상) | **49** | **99.1%** |
| ML 계획 (커버리지만 고려) | 31 | 98.6% |
| 같은 실행 수를 무작위로 고름 | 49 | 43.5% |
| CI smoke (기존) | 36 | 0.0% (top 커버리지 77%) |

**한계:** 이 수치는 재설계 전 테스트 목록으로 측정한 것입니다. 재설계에서 추가한 테스트는 학습 데이터에 없어서,
smoke에서 계획과 별도로 seed 1개씩 돌립니다.

- 전체 데이터로 학습한 47회 계획을 실제로 돌려 6개 TB 모두 100% (183/183 bin), fail 0, xfail 4를 확인했습니다.
- unit TB는 테스트당 seed 1개로 포화되고, 추가 seed는 모두 top에 배정됩니다 (`dma_rand_test` x4,
  `dma_irq_test` x3, `dma_size_edge_test` x2). smoke는 고유 bin 5개를 가진 `dma_size_edge_test`가 빠져 있어
  top 커버리지가 77%에 머뭅니다.
- `xcrg` 2022.2 텍스트 보고서의 문제를 파서에서 처리합니다. 두 번째 cross 표가 첫 번째 cross의 내용으로
  중복 출력되고 (그래서 top의 `x_dir_4k`는 모델에서 빠짐), 못 친 cross bin은 `(a b)`·`*`로 묶여 나오며,
  weight 0인 참고용 cross(`x_io`)가 섞여 있습니다.
- **CI 적용**: Jenkins smoke(push마다)가 `verif/regress_plan.json`대로 돌고, `ml_regress.py check`로 목표 bin을 모두
  채웠는지 확인합니다 (못 채우면 UNSTABLE). 테스트를 추가하면 `analyze --save-plan verif/regress_plan.json`으로 계획을
  다시 만듭니다. 계획에 없는 테스트는 경고와 함께 `--seeds` 수로 돌아 빠지지 않습니다.
- 딥러닝이 아니라 확률 모델입니다. 커버리지 공간이 작아서 절대 시간보다 비율이 의미 있습니다.

## 보드 시험 (Zybo Z7-10)

같은 시험 7개(8B~1MB, burst 경계, 4KB 경계, `add_val` 0/255 포함)를 두 가지 방식으로 실제 DDR에서 실행합니다.
판정 기준은 바이트마다 `대상 = (원본 + add_val) & 0xFF`입니다.

| 방식 | 명령 | 하는 일 |
|---|---|---|
| JTAG | `python scripts/board.py --xsa out/fpga/system_xc7z010/design_1_wrapper.xsa` | xsdb가 데이터를 DDR에 쓰고 DMA 레지스터를 직접 구동, 결과를 읽어 Python이 비교 (하드웨어만 확인) |
| ARM C | `python scripts/board_c.py` | xsct로 BSP와 ELF 빌드 → xsdb로 비트스트림, PS 초기화, ELF 실행 → Cortex-A9의 C 프로그램이 DMA를 구동하고 스스로 판정 |

C 프로그램(`fw/dma_board_test/dma_board_test.c`)이 하는 일:
- D-cache를 켠 채로 DMA 전에 원본/대상 범위를 flush하고, DMA 뒤 대상 범위를 invalidate합니다 (HP0 포트는 cache coherent가 아님).
- 레지스터 설정 → IDLE 확인 → `ap_start` → DONE 대기 (1초 넘으면 HANG).
- 결과를 UART(115200)로 출력하고 DDR mailbox(`0x0F000000`)에도 씁니다. `board_c.py`는 JTAG로 mailbox를 읽어
  UART 로그와 판정이 같은지 확인하고, 다르면 실패로 처리합니다.

필요한 것: Vivado 2022.2 (xsdb), Vitis 2022.2 (xsct, ARM 컴파일러, C 방식만), Zybo의 USB-UART 포트
(기본 `COM7`, `--com`으로 변경). 결과는 `out/board/<시각>/`, `out/board_c/<시각>/result.json`에 남습니다.

결과 (2026-11-17, 두 방식 모두 7/7 PASS. 재설계 뒤 release 판정을 위해 2026-11-21에 다시 해서 JTAG 7/7, ARM C 7/7 PASS):

| 시험 | 크기 | DMA (C) | CPU memcpy |
|---|---|---|---|
| page4k | 4 KB | 6.0 µs | 2.1 µs |
| c_ref_64k | 64 KB | 84 µs (779 MB/s) | 63 µs |
| big_1m | 1 MB | 1332 µs (787 MB/s) | 2869 µs (366 MB/s) |

1MB에서 DMA는 64-bit × 100MHz 이론값(800 MB/s)의 98%입니다. 작은 크기에서는 원본이 cache에 남아 있어 CPU가
빠르게 나오므로, L2(512KB)보다 큰 1MB만 공정한 비교입니다. DMA 시간에는 DONE 폴링 지연이 포함됩니다.

## 문서

| 주제 | 문서 |
|---|---|
| 저장소 구조와 스크립트 | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| UVM 테스트벤치 구조 | [docs/UVM_STRUCTURE.md](docs/UVM_STRUCTURE.md) |
| 개발, CI 단계, 실패했을 때의 흐름 | [docs/FLOW.md](docs/FLOW.md) |
| 테스트벤치 목록과 XSim 주의점 | [verif/README.md](verif/README.md) |
| sign-off 기준, waiver, 판정 기록 | [verif/SIGNOFF.md](verif/SIGNOFF.md) |
| RTL 버그와 설계 노트 | [verif/BUGS.md](verif/BUGS.md) |
| 기능별 검증 계획과 가설 (원본 `verif/plan.toml`) | [verif/vplan/vplan.md](verif/vplan/vplan.md) |
| Jenkins 설치와 운영, FPGA, 보드 시험 | [ci/README.md](ci/README.md) |
| MCP 서버 | [mcp/README.md](mcp/README.md) |
| 에이전트 작업 규칙 | [CLAUDE.md](CLAUDE.md) |
| 검증·CI/CD 결과 보고서 (2026-11-21 기준) | [docs/REPORT.md](docs/REPORT.md) |

문서의 경로, 클래스 이름, 표는 `python scripts/check_docs.py`가 코드와 비교합니다.
