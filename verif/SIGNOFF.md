# Sign-off 기준

이 IP의 검증을 "끝났다"고 말하려면 아래 기준 S1~S11을 모두 만족해야 합니다. 판정은 사람이 아니라
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
| S2 | 예상된 실패(XFAIL)는 승인된 `known_fail`만이고, `sim_cfg.json`의 known_fail, `plan.toml`의 bugs, `BUGS.md`의 버그 절이 서로 맞음 | ● | ● | ● | `verif/sim_cfg.json`, `verif/plan.toml`, `verif/BUGS.md` (`plan_check.py`) |
| S3 | 테스트가 등록된 모든 TB와 모든 테스트 실행(통째로 빠진 TB 없음), 테스트당 seed 1개(smoke) / 5개(nightly, release) 이상 | ● | ● | ● | `out/regress/*/summary.json` |
| S4 | 기능 커버리지 100% (회귀에 나온 모든 TB, xcrg 병합 점수) | ● | ● | ● | `out/<tb>/cov/func/xcrg_func_cov_report.txt` |
| S5 | ML 회귀 계획의 목표 bin(183개)을 모두 채움 | ● | | | `out/ml/check.json` |
| S6 | DMA 단독(OOC) 100MHz 타이밍 WNS ≥ 0, WHS ≥ 0 | ● | ● | ● | `out/fpga/ooc/result.json` |
| S7 | 시스템 빌드(PS + DMA) WNS ≥ 0, WHS ≥ 0, 비트스트림과 XSA 생성 | | ● | ● | `out/fpga/system/result.json` |
| S8 | 실보드 시험 PASS: JTAG(`board.py`)와 ARM C(`board_c.py`) 최근 결과 모두 | | | ● | `out/board/<시각>/`, `out/board_c/<시각>/` |
| S9 | 검증 계획(`plan.toml`)에 등록된 모든 테스트가 있고, blocked 기능은 버그나 가설을 가리키며, 검사 ID와 커버포인트가 실재하고, `vplan.md`가 최신 | ● | ● | ● | `verif/plan.toml`, `verif/vplan/vplan.md` (`plan_check.py`) |
| S10 | 근거 파일이 모두 같은 커밋에서 나옴(출처 없는 결과는 FAIL). release는 수정 없는 checkout이어야 하고, 보드에 올린 XSA는 승인된 RTL로 만든 시스템 빌드여야 함 | ● | ● | ● | 각 결과의 `provenance`, `out/fpga/system*/result.json`의 XSA sha256 |
| S11 | HW/ 내용 해시가 `plan.toml`의 승인된 값과 같음(지금 checkout과 모든 근거). RTL이 바뀌면 사람이 확인하고 값을 갱신 | ● | ● | ● | `verif/plan.toml` `[rtl]`, `scripts/common.py` `hw_hash` |

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
| BUG-003 | 작업을 한 번 끝낸 뒤 AWREADY가 늦으면 W FSM이 이전 burst 길이로 W beat를 셈 (WLAST 오류, 멈춤) | open (RTL 담당자 결정 대기, waiver 승인 대기) | `dma_aw_wait_after_job_test` | BUG-002와 같은 조건이고 여러 작업을 돌리는 실제 사용에서 주로 나타남. BUG-002 처음 수정안으로는 안 고쳐짐 |
| BUG-004 | B 응답이 느리면 W->B FIFO가 넘쳐 B 항목을 잃고 멈춤 (AW 지연 불필요) | open (RTL 담당자 결정 대기, waiver 승인 대기) | `dma_slow_b_test` | HP 포트의 B가 W보다 약 80사이클 넘게 밀리면 발생. 보드 측정 필요 |
| BUG-005 | 작업 중 start나 auto_restart 뒤에는 리셋 전까지 start가 먹지 않음 (RDMA만 끝난 구간이면 AW 없는 W) | open (RTL 담당자 결정 대기, waiver 승인 대기) | `dma_start_busy_test`, `dma_auto_restart_test` | 제공 SW(idle 확인 뒤 start, auto_restart 안 씀)에서는 안 걸림. start를 두 번 쓰는 드라이버는 PL 리셋으로만 복구 |
| BUG-006 | 작업 도중 리셋하면 adder 잔여 beat가 AW 없이 나가 이후 작업 데이터가 조용히 밀림 | open (RTL 담당자 결정 대기, waiver 승인 대기) | `dma_reset_mid_job_test` | 제공 SW는 작업 중 리셋 안 함. 멈춤 복구로 PL 리셋을 쓰면 그 뒤 데이터가 틀림 (done은 정상) |
| BUG-007 | 24비트 beat 카운터로 128MiB 이상은 일부만 복사하거나 멈춤 | open (RTL 담당자 결정 대기, waiver 승인 대기) | `dma_size_128mib_test` | 제공 SW는 64MiB 제한이라 안 걸림. 수정은 NOTE-001 타이밍과 함께 확인 |
| NOTE-002 | 작업 중 VALUE_TO_ADD 변경은 그 뒤 R beat부터 적용 | 설계 노트 (사용자 결정: 동작 문서화) | `dma_busy_reg_write_test` (PASS) | SW는 start 전에 값을 써야 함 (제공 SW는 그렇게 함) |
| NOTE-003 | 리셋 뒤 2사이클 동안 DUT WVALID가 1로 남음 | 설계 노트 | (H4 trace) | 낮음. 리셋 중 READY=1인 slave에서만 의미 있음 |

## 판정 기록

### Jenkins smoke 추이

| 빌드 | smoke 방식 | 결과 | 테스트 (pass / skip(XFAIL) / fail) | OOC WNS | 계획 목표 bin | Sign-off | 시간 |
|---|---|---|---|---|---|---|---|
| tb-redesign #11 | ML 계획 (58회) | SUCCESS | 48 / 10 / 0 | +0.014ns | 183/183 | **smoke PASS** | 13.6분 |
| #27 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | **smoke PASS** | 9.3분 |
| #26 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | (단계 없음) | 9.5분 |
| #25 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | (단계 없음) | 10.3분 |
| #24 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 9.2분 |
| #23 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 10.7분 |
| #22 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 9.0분 |
| #21 | 예전 smoke (36회) | SUCCESS | 32 / 4 / 0 | +0.014ns | – | – | 8.8분 |

- #26의 결과 파일로 `signoff.py --level smoke`를 돌리면 S1~S6이 PASS였습니다. S9만 FAIL이었는데,
  `dma_smoke_test`와 dma_small_test(0-2단계에서 `dma_short_job_test`로 이름을 바꿈)가 vplan에 없었기 때문입니다. 이 sign-off 검사를 만들면서 찾은
  누락이고, vplan에 두 행을 추가해 고쳤습니다.
- #27은 Sign-off 단계가 처음 돈 빌드입니다. smoke 수준의 S1~S6, S9가 모두 PASS였습니다(S7, S8은 smoke에서 보지 않음).
### Jenkins nightly(full) 추이

| 빌드 | 결과 | 회귀 (runs / fail / xfail) | 테스트 (pass / skip / fail) | 커버리지 | OOC WNS | 시스템 WNS / WHS | 비트스트림 | Sign-off | 시간 |
|---|---|---|---|---|---|---|---|---|---|
| #40 | SUCCESS | 265 / 0 / 50 | 215 / 50 / 0 | adder=100 adder8=100 fifo=100 fifo_d4=100 skid=100 top=100 | +0.014ns | +0.003ns / +0.011ns | `.bit` 4,045,676B, `.xsa` 679,410B | **nightly PASS** | 36.4분 |
| #34 | SUCCESS | 260 / 0 / 50 | 210 / 50 / 0 | adder=100 adder8=100 fifo=100 fifo_d4=100 skid=100 top=100 | +0.014ns | +0.003ns / +0.011ns | `.bit` 4,045,676B, `.xsa` 679,401B | **nightly PASS** | 41.6분 |
| tb-redesign #12 | SUCCESS | 260 / 0 / 50 | 210 / 50 / 0 | adder=100 adder8=100 fifo=100 fifo_d4=100 skid=100 top=100 | +0.014ns | +0.003ns / +0.011ns | `.bit` 4,045,676B, `.xsa` 679,418B | **nightly PASS** | 36분 |
| #28 | SUCCESS | 205 / 0 / 20 | 185 / 20 / 0 | 6개 TB 100 | +0.014ns | +0.003ns / +0.011ns | `.bit` 4,045,676B, `.xsa` 679,404B | **nightly PASS** | 33.4분 |

- #40은 `dma_axil_timing_test`(AXI-Lite 타이밍 변화)를 추가한 뒤 2026-11-22에 수동으로 돌린 full 빌드입니다
  (`MODE=full`, 커밋 `2e8c451`). 등록 조합이 52개에서 53개로 늘어 265회이고, 새 테스트는 seed 5개 모두 PASS입니다.
  full을 바로 돌리려고 같은 코드의 smoke 빌드 #38(`8fdf654`)과 #39(`2e8c451`)는 중간에 멈췄습니다(ABORTED).
- #34는 tb-redesign을 main에 병합한 뒤 2026-11-21에 수동으로 앞당겨 돌린 full 빌드입니다 (`MODE=full`, 커밋
  `5b53124`, 결과는 tb-redesign #12와 같음). 같은 커밋의 smoke 빌드 #32도 SUCCESS, smoke sign-off PASS였습니다
  (58회 fail 0, 빌드 로그 기준. 작업 폴더가 #34로 덮여 표에는 넣지 않음).
- #28은 2026-11-18에 수동으로 앞당겨 돌린 full 빌드입니다 (`MODE=full`, 타이머 nightly와 같은 단계).
- xfail 20 = known_fail 4개 × seed 5개. 모두 BUG-001, BUG-002 재현입니다.

### release 판정 (2026-11-18)

**판정: PASS, 조건부 출시 (BUG-002 waiver).** `signoff.py --level release`로 #28의 결과 파일과 보드 시험 결과를
함께 판정했습니다. 판정 대상 S1~S4, S6~S9가 모두 PASS입니다 (S5는 smoke 전용).

| 기준 | 근거 | 결과 |
|---|---|---|
| S1 회귀 | #28: 205회, fail 0, 빌드 실패 0 | PASS |
| S2 waiver | xfail 20 = 승인된 known_fail 4개 (BUG-001, BUG-002) | PASS |
| S3 seed | 등록 테스트 41개 모두, 테스트당 seed 5개 | PASS |
| S4 커버리지 | adder, adder8, fifo, fifo_d4, skid, top 모두 100 | PASS |
| S6 OOC 타이밍 | WNS +0.014ns, WHS +0.125ns (xc7z020) | PASS |
| S7 시스템 타이밍 | #28: WNS +0.003ns, WHS +0.011ns, 비트스트림·XSA 생성 (xc7z010 빌드: WNS +0.005ns, WHS +0.008ns) | PASS |
| S8 보드 (JTAG) | `board.py`, Zybo Z7-10, 2026-11-16: 7/7 | PASS |
| S8 보드 (ARM C) | `board_c.py`, Zybo Z7-10, 2026-11-17: 7/7, UART와 mailbox 일치 (2회) | PASS |
| S9 vplan | 등록 테스트 17종 모두 계획에 있음, ❌ 행 2개 모두 버그 ID 있음 | PASS |

- 보드 시험은 #28보다 먼저 했지만, `HW/` RTL은 첫 커밋(2026-11-14) 뒤로 바뀌지 않았으므로 같은 설계에 대한 근거로 씁니다.
- **출시 노트에 적을 조건:**
  - BUG-002 (open): AWREADY를 늦추는 interconnect나 slave에 연결하면 hang 위험이 있습니다. 현재 확인된 구성은 Zynq HP0 직결뿐입니다.
  - BUG-001 (won't fix): 리셋 해제 직후 같은 사이클에 입력을 넣지 않습니다.
  - NOTE-001: 타이밍 여유가 +0.003ns이므로, RTL이나 구현 설정을 바꾸면 S6·S7을 다시 확인합니다.

### release 판정 (2026-11-21, 재설계 뒤)
- **근거:** 커밋 `94accfa`, 수정 없는 checkout에서 `python scripts/signoff.py --level release` → **PASS**
  (S1~S4, S6~S11 PASS, S5 N/A). 판정 결과 원본: `out/loop/release/signoff_release_94accfa.md`(로컬).
  - 전체 회귀 seed 5: 260회 fail 0, XFAIL 50(known_fail 10개 × seed 5), 커버리지 6개 TB 100%
  - OOC(xc7z020) WNS +0.014ns / WHS +0.125ns, 시스템 빌드(xc7z010) WNS +0.005ns / WHS +0.008ns, 비트스트림·XSA
  - Zybo Z7-10 보드: JTAG `board.py` 7/7 PASS, ARM C `board_c.py` 7/7 PASS(1MB 787 MB/s, mailbox와 UART 판정 일치)
  - HW 해시 `9fdca2f0cc594a65` (승인값과 같음, checkout과 모든 근거)
- **판정:** 조건부 출시. BUG-002~007이 open이고 waiver는 RTL 담당자 결정 대기입니다.
- **출시 노트에 적을 조건:**
  - AWREADY나 B 응답을 늦추는 interconnect에서 사용 금지 (BUG-002, BUG-003, BUG-004)
  - start는 idle 확인 뒤 한 번만 쓰고, auto_restart는 쓰지 않음 (BUG-005)
  - 작업 도중 PL 리셋을 했다면 그 뒤 작업 결과를 신뢰하지 말 것 (BUG-006)
  - transfer_byte는 128MiB 미만 (BUG-007)
  - BUG-001(won't fix), NOTE-001(타이밍 여유) 조건은 2026-11-18 판정과 같음
