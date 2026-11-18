# Sign-off 기준

이 IP의 검증을 "끝났다"고 말하려면 아래 기준 S1~S9를 모두 만족해야 합니다. 판정은 사람이 아니라
`scripts/signoff.py`가 결과 파일로 하고, CI는 빌드마다 이 판정을 남깁니다(`out/signoff/signoff.md`).

```bash
python scripts/signoff.py --level smoke      # push마다
python scripts/signoff.py --level nightly    # 매일 밤 (full)
python scripts/signoff.py --level release    # 출시 판정 (보드 시험 결과 포함)
```

## 판정 수준

| 수준 | 언제 | 무엇을 보장하나 | 실패하면 |
|---|---|---|---|
| `smoke` | push마다 (Jenkins smoke) | 바뀐 코드가 기존 기능과 커버리지를 깨지 않음 | 빌드 UNSTABLE, 다음 push 전에 원인 확인 |
| `nightly` | 매일 02:00 (Jenkins full) | 모든 테스트를 seed 5개로, 시스템 타이밍과 비트스트림까지 | 빌드 UNSTABLE, 다음 날 triage |
| `release` | 출시 판정 때 (수동) | nightly + 실보드 시험 (JTAG, ARM C) | 출시하지 않음 |

## 기준

| ID | 기준 | smoke | nightly | release | 근거 파일 |
|---|---|---|---|---|---|
| S1 | 회귀 fail 0 (XPASS, NO_RESULT 포함), 빌드 실패 0 | ● | ● | ● | `out/regress/*/summary.json` |
| S2 | 예상된 실패(XFAIL)는 승인된 `known_fail`만이고, 각각 `BUGS.md`에 ID와 상태가 있음 | ● | ● | ● | `verif/sim_cfg.json`, `verif/BUGS.md` |
| S3 | 등록된 모든 테스트 실행, 테스트당 seed 1개(smoke) / 5개(nightly, release) 이상 | ● | ● | ● | `out/regress/*/summary.json` |
| S4 | 기능 커버리지 100% (회귀에 나온 모든 TB, xcrg 병합 점수) | ● | ● | ● | `out/<tb>/cov/func/xcrg_func_cov_report.txt` |
| S5 | ML 회귀 계획의 목표 bin(183개)을 모두 채움 | ● | | | `out/ml/check.json` |
| S6 | DMA 단독(OOC) 100MHz 타이밍 WNS ≥ 0, WHS ≥ 0 | ● | ● | ● | `out/fpga/ooc/result.json` |
| S7 | 시스템 빌드(PS + DMA) WNS ≥ 0, WHS ≥ 0, 비트스트림과 XSA 생성 | | ● | ● | `out/fpga/system/result.json` |
| S8 | 실보드 시험 PASS: JTAG(`board.py`)와 ARM C(`board_c.py`) 최근 결과 모두 | | | ● | `out/board/<시각>/`, `out/board_c/<시각>/` |
| S9 | 등록된 모든 테스트가 `vplan.md`에 있고, ❌ 행은 버그 ID를 가짐 | ● | ● | ● | `verif/vplan/vplan.md` |

- S4는 커버리지 점수만이 아니라 **bin 분포**도 봅니다. 한 bin에 샘플이 몰리면(예전 `[513:$]` 오탐) 점수가
  100이어도 의심합니다. 이 검사는 아직 사람이 합니다.
- S5는 smoke에서만 봅니다. 계획은 교차 검증에서 100% 도달 확률이 99.1%라, 드물게 실패할 수 있습니다.
  실패하면 먼저 같은 계획을 다시 돌려 재현되는지 확인합니다.
- S8은 보드를 이 PC에 연결해야 해서 CI에서 돌지 않습니다. 출시 판정 직전에 사람이 돌리고, 그 결과
  파일이 근거가 됩니다.

## 예상된 실패(waiver) 승인 절차

테스트를 통과시키려고 검사를 낮추거나 테스트를 빼지 않습니다. 실패가 RTL 버그로 확정되면 다음 순서로
`known_fail`에 등록하고, 이 등록이 곧 waiver입니다.

1. `sim-triage`(또는 사람)가 실패를 RTL 버그로 분류하고 증거(로그, 파형, 재현 명령)를 남깁니다.
2. 검증 담당자가 `verif/BUGS.md`에 증상, 원인, 재현, 수정안, 상태를 적습니다.
3. **RTL 담당자가 상태를 정합니다**: open(수정 예정) 또는 won't fix.
4. 재현 테스트를 `verif/sim_cfg.json`의 `known_fail`에 `"BUG-xxx: 한 줄 설명"`으로 등록합니다.
   S2가 이 ID를 `BUGS.md`에서 찾지 못하면 sign-off가 실패합니다.
5. RTL이 고쳐지면 그 테스트가 XPASS가 되고 S1이 실패합니다. 그때 `known_fail`을 지우고 버그를
   closed로 바꿉니다. 수정이 조용히 지나가지 않습니다.

**출시 판정에서 open 상태의 waiver가 있으면, 출시 노트에 그 버그와 영향을 반드시 적습니다.**

## 현재 waiver

| ID | 내용 | 상태 | 재현 테스트 | 출시 영향 |
|---|---|---|---|---|
| BUG-001 | 리셋 직후 skid buffer가 첫 beat를 중복 출력 | won't fix (RTL 담당자 결정) | `unit_post_reset_test` (fifo, fifo_d4, skid) | 리셋 해제 직후 같은 사이클에 입력이 오는 사용에서만 발생 |
| BUG-002 | AWREADY가 늦으면 WDMA가 W beat를 잘못 세어 멈춤 | open (RTL 담당자 결정 대기) | `dma_aw_backpressure_test` | 현재 보드(HP0 직결)에서는 재현 안 됨. interconnect가 AWREADY를 늦추면 hang 위험 |
| NOTE-001 | WDMA 주소 경로 타이밍 여유 부족 | 설계 노트 (기능 버그 아님) | S6, S7 | 구현 전략(Explore + phys_opt)으로 통과. RTL 변경 시 다시 깨질 수 있음 |

## 판정 기록

### Jenkins smoke 추이

| 빌드 | smoke 방식 | 결과 | 테스트 (pass / skip(XFAIL) / fail) | OOC WNS | 계획 목표 bin | Sign-off | 시간 |
|---|---|---|---|---|---|---|---|
| #27 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | **smoke PASS** | 9.3분 |
| #26 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | (단계 없음) | 9.5분 |
| #25 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | (단계 없음) | 10.3분 |
| #24 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 9.2분 |
| #23 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 10.7분 |
| #22 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 9.0분 |
| #21 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 8.8분 |

- #26의 결과 파일로 `signoff.py --level smoke`를 돌리면 S1~S6이 PASS였습니다. S9만 FAIL이었는데,
  `dma_smoke_test`와 `dma_small_test`가 vplan에 없었기 때문입니다. 이 sign-off 검사를 만들면서 찾은
  누락이고, vplan에 두 행을 추가해 고쳤습니다.
- #27은 Sign-off 단계가 처음 돈 빌드입니다. smoke 수준의 S1~S6, S9가 모두 PASS였습니다(S7, S8은 smoke에서 보지 않음).
- nightly(full) 판정은 아직 기록이 없습니다. 첫 nightly 빌드 결과가 나오면 여기에 추가합니다.

### release 근거 (2026-11-18 기준)

| 기준 | 근거 | 결과 |
|---|---|---|
| S7 시스템 타이밍 | `fpga.py system` (xc7z020: WNS +0.003ns, WHS +0.011ns / xc7z010: WNS +0.005ns, WHS +0.008ns) | PASS |
| S8 보드 (JTAG) | `board.py`, Zybo Z7-10, 2026-11-16: 7/7 | PASS |
| S8 보드 (ARM C) | `board_c.py`, Zybo Z7-10, 2026-11-17: 7/7, UART와 mailbox 일치 (2회) | PASS |
| S3 seed 5개 이상 | 첫 nightly 결과 대기 | 미정 |

**release 판정: 보류.** S3(seed 5개 full 회귀)와 nightly 기준의 S4를 첫 nightly 결과로 확인한 뒤 판정합니다.
BUG-002가 open이라, 출시하더라도 출시 노트에 "AWREADY를 늦추는 interconnect에서는 사용 금지"를 적어야 합니다.
