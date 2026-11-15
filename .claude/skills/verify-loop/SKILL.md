---
name: verify-loop
description: dma-uvm의 검증 반복 한 번을 지휘합니다. verif-planner로 계획하고, uvm-builder/coverage-closer로 구현하고, 실행과 회귀를 돌리고, sim-triage로 실패를 분류하고, ci-watcher로 CI를 확인합니다. RTL 버그와 커밋에서는 사람의 확인을 받습니다. 사용자가 기능 검증, 커버리지 채우기, CI 실패 조사, "루프 돌리기"를 요청할 때 사용합니다.
---
# verify-loop: orchestrator 절차

당신은 orchestrator입니다. 일은 서브에이전트가 하고, 당신은 상태, 확인 지점(gate), 요약을
관리합니다. 먼저 CLAUDE.md를 읽으세요. HW/ 수정은 누구든 hook이 막습니다.

## 0. 이번 반복 정하기
목표를 한 줄로, 그리고 완료 기준을 적습니다. 기본값:
- 영향받는 suite의 모든 테스트가 seed 3개에서 기대와 일치 (PASS, 또는 알려진 버그는 XFAIL),
- 대상 covergroup 100% (또는 남은 구멍을 모두 사용자가 명시적으로 받아들임),
- 영향받는 suite의 회귀에서 새 UVM_ERROR/UVM_FATAL 없음.

## 1. 계획 → `verif-planner`
목표를 넘깁니다. 의존 관계와 병렬 묶음이 표시된 작업 표를 돌려받습니다.
사람이 결정해야 할 질문이 있으면 구현 전에 사용자에게 묻습니다.

## 2. 구현 → `uvm-builder` / `coverage-closer`
- 작업 하나에 서브에이전트 하나. 서로 다른 파일을 건드리는 작업은 **병렬로** 돌려도 됩니다.
  같은 파일을 건드리는 작업 (예: 둘 다 `dma_test_pkg.sv`에 `` `include ``를 추가하거나 둘 다
  `sim_cfg.json`을 고침)은 **차례로** 돌립니다.
- 각자 바뀐 파일과 재실행 명령이 붙은 판정을 돌려줍니다. 내가 의존하는 주장은 다시 확인합니다
  (예: seed 하나로 `python scripts/sim.py run ... --no-build`를 직접 실행).

## 3. 회귀
`start_regression` (vivado MCP) 또는 `python scripts/regress.py --suite <unit|top|all> --seeds 3`.
깨끗한 결과는 `fail=0`입니다. XFAIL 항목은 알려진 BUG-00x 재현 테스트뿐이어야 합니다.

## 4. 분류 → `sim-triage` (실패 증상마다 하나씩, 병렬로)
분류에 따라 처리합니다:
| 분류 | 처리 |
|---|---|
| TB 버그 | 증거를 들고 2단계로 돌아감 |
| 알려진 버그 | 할 일 없음. XPASS면 RTL이 고쳐진 것 같다고 사용자에게 알리고 known_fail 삭제를 제안 |
| **RTL 버그** | **GATE: 멈춤.** 사용자에게 증거와 BUGS.md 항목 초안을 보여 줌. 승인 후 BUGS.md + `known_fail` 추가 (HW/는 절대 수정 안 함) |
| 환경 | 우리 스크립트/시간 설정 문제면 고치고, 아니면 보고 |

## 5. 커버리지
영향받는 TB의 `coverage_report`를 실행하고 반복 시작 때와 비교합니다. 구멍이 남으면 → 2단계
(coverage-closer), 또는 사용자에게 받아들일지/제외할지 묻습니다.

## 6. CI → `ci-watcher`
최근 빌드를 보고합니다. 사용자가 커밋/push를 요청한 뒤에만 (**GATE: 스스로 하지 않음**)
다음 SCM poll이 smoke 빌드를 돌립니다. ci-watcher에게 결과를 받고, 실패는 4단계로 보냅니다.

## 7. 보고
짧은 표로 보여 줍니다: 끝낸 작업, 추가한 테스트, 회귀 집계(runs/fail/xfail), 커버리지
전 → 후, 새 버그, 남은 질문. 모든 숫자는 이번 반복에서 실제로 돌린 결과여야 합니다.

## 멈추는 조건
완료 기준을 만족했거나, 구현/분류를 2번 반복해도 같은 실패가 남았거나 (증거와 함께 사용자에게
올림), gate에서 사용자를 기다리는 중일 때.
