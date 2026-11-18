# dma-uvm-verif

간단한 AXI DMA IP(`dma_ip_top`: RDMA → FIFO → adder → FIFO → WDMA, AXI4-Lite 제어, AXI4 master)를
Vivado 2022.2 XSim에서 검증하는 UVM 환경, CI/CD, 에이전트 도구입니다. 기본 대상은 Zybo Z7-20
(xc7z020clg400-1)이고, 실보드 시험은 Zybo Z7-10(xc7z010clg400-1)에서 했습니다.

**포트폴리오 페이지:** https://socdesignasic.github.io/dma-uvm-verif/

> **DUT RTL은 들어 있지 않습니다.** 이 저장소에는 검증 코드만 있습니다. 실행하기 전에
> 다음을 추가하세요 (모두 이 저장소의 git에서 무시됨):
> - `HW/`: DUT RTL. 테스트벤치는 `verif/filelist/rtl.f`와 unit filelist에 적힌 파일과 모듈 이름을
>   기대합니다 (top 모듈 `dma_ip_top`)
> - `uvm_reference/`: 참고용 UVM 예제 (`ref_adder*` 테스트벤치만 사용)
> - `ci/vivado/ip/dma_ip_top/`: IP 패키징 메타데이터 (`component.xml`, `xgui/`).
>   `scripts/fpga.py system`(비트스트림 빌드)에만 필요
> - `SW/`: 참조용 보드 예제 (쓰지 않음. C 보드 시험은 `fw/`에 새로 작성)

## 구성

| 경로 | 내용 |
|---|---|
| `verif/` | UVM 테스트벤치: agent, env, sequence, 테스트, TB top, 테스트 목록(`sim_cfg.json`), vplan, 버그 목록, sign-off 기준(`SIGNOFF.md`) |
| `scripts/` | `sim.py` (lint/실행/커버리지), `regress.py` (병렬 회귀, `--plan`), `ml_regress.py` (커버리지 모델 학습과 회귀 계획), `signoff.py` (sign-off 판정), `fpga.py` (OOC 타이밍, 비트스트림 + XSA), `board.py` / `board_c.py` (보드 시험) |
| `fw/dma_board_test/` | Cortex-A9 bare-metal C 보드 시험 프로그램 (Vitis standalone BSP) |
| `Jenkinsfile`, `ci/` | 로컬 Jenkins (Configuration as Code), Vivado 블록 디자인과 IP 패키징, xsdb 보드 시험(`ci/vivado/board_*.tcl`), Vitis 빌드(`ci/vitis/`) 스크립트 |
| `mcp/` | 시뮬레이션 흐름을 에이전트에 제공하는 MCP 서버 |
| `.claude/`, `CLAUDE.md` | 에이전트 규칙, 서브에이전트, `/verify-loop` 스킬, `HW/`를 읽기 전용으로 지키는 hook |
| `docs/` | 결과 보고서, 저장소 구성, 흐름, UVM 코드 구조 |

## 빠른 시작 (`HW/`에 RTL을 넣은 뒤)

```bash
python scripts/sim.py list
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top
```

## Sign-off

"검증이 끝났다"는 `verif/SIGNOFF.md`의 기준 S1~S9로 정하고, `scripts/signoff.py`가 결과 파일로 판정합니다.
Jenkins는 모든 빌드 끝에 Sign-off 단계를 돌려 `out/signoff/signoff.md`를 남기고, 기준을 못 채우면 UNSTABLE로 표시합니다.

| 수준 | 언제 | 보는 기준 |
|---|---|---|
| `smoke` | push마다 | 회귀 fail 0, XFAIL은 승인된 known_fail만, 모든 테스트 실행, 커버리지 100%, ML 계획 목표 bin 전부, OOC 타이밍, vplan 완결성 |
| `nightly` | 매일 밤 | smoke 기준(ML 계획 제외) + 테스트당 seed 5개 + 시스템 빌드 타이밍과 비트스트림 |
| `release` | 출시 판정 | nightly + 실보드 시험(JTAG, ARM C) |

- **waiver = known_fail 승인:** RTL 버그 확정 → `BUGS.md` 기록 → RTL 담당자가 상태 결정 → 재현 테스트를 `known_fail`로 등록.
  RTL이 고쳐지면 XPASS로 빌드가 실패해 수정이 조용히 지나가지 않습니다.
- 판정을 처음 돌렸을 때 S9가 vplan에 빠진 테스트 2개(`dma_smoke_test`, `dma_small_test`)를 찾아 고쳤습니다.

```bash
python scripts/signoff.py --level smoke      # nightly, release
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
| CI smoke | 36 | 0.0% (top 커버리지 77%) |

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

결과 (2026-11-17, 두 방식 모두 7/7 PASS):

| 시험 | 크기 | DMA (C) | CPU memcpy |
|---|---|---|---|
| page4k | 4 KB | 6.0 µs | 2.1 µs |
| c_ref_64k | 64 KB | 84 µs (779 MB/s) | 63 µs |
| big_1m | 1 MB | 1332 µs (787 MB/s) | 2869 µs (366 MB/s) |

1MB에서 DMA는 64-bit × 100MHz 이론값(800 MB/s)의 98%입니다. 작은 크기에서는 원본이 cache에 남아 있어 CPU가
빠르게 나오므로, L2(512KB)보다 큰 1MB만 공정한 비교입니다. DMA 시간에는 DONE 폴링 지연이 포함됩니다.

자세한 내용은 `docs/ARCHITECTURE.md`, `docs/FLOW.md`, `docs/UVM_STRUCTURE.md`를,
이 환경이 찾은 RTL 문제는 `verif/BUGS.md`를 보세요.
