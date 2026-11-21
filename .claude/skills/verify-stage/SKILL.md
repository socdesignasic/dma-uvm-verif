---
name: verify-stage
description: 재설계 단계 하나(TB 1단계, 2단계 등)나 검증 목표 하나를 gate.py가 PASS할 때까지 진행합니다. verif-planner로 작업을 나누고, uvm-builder를 worktree에서 돌리고, tb-reviewer로 검토한 뒤, 사람 확인을 받아 병합하고 gate로 판정합니다. ledger에 기록해 다른 세션에서 이어 갈 수 있습니다. 사용자가 "N단계 진행", "이 기능 검증해" 처럼 단계나 목표를 맡길 때 사용합니다. CI 실패 조사만이면 ci-check를 씁니다.
---
# verify-stage: 단계 진행 절차

당신은 orchestrator입니다. 일은 서브에이전트가 하고, 당신은 순서, 사람 확인 지점, 기록을 관리합니다.
먼저 CLAUDE.md를 읽으세요. "끝났다"는 글이 아니라 `scripts/gate.py <단계>`의 결과로 말합니다(규칙 6).

## 준비
1. 입력: 단계 이름(gate.py에 있는 이름, `python scripts/gate.py --list`) 또는 목표, 그리고 ledger id
   (없으면 `stage<이름>`처럼 새로 정함).
2. `ledger_read`로 지난 기록을 봅니다. 이어 가는 중이면 마지막 항목부터 시작합니다.

## 반복
1. **계획:** verif-planner에 목표와 ledger id를 줍니다. 작업 목록(건드릴 파일, 통과 기준, 병렬 묶음)을 받습니다.
   planner가 plan.toml을 고쳤으면 `python scripts/plan_check.py --write`를 돌립니다.
2. **구현:** 작업마다 작업 폴더를 직접 만듭니다: `git worktree add --detach <scratchpad>/<작업 id> <작업 브랜치>`.
   Agent의 isolation: worktree는 기본 브랜치(main)에서 만들어지므로 쓰지 않습니다(C단계 시험에서 확인).
   uvm-builder에게 그 경로를 넘깁니다. 건드릴 파일이 겹치지 않는 작업은 병렬로 띄웁니다. 각 builder의 작업 폴더 경로와 결과를 `ledger_append`로 남깁니다.
3. **검토:** builder마다 tb-reviewer에 작업 폴더, 작업 설명, builder 결과를 줍니다.
   "수정 요청"이면 그 내용을 붙여 같은 builder에게 다시 맡깁니다(최대 2번).
4. **병합 (사람 확인):** 승인된 작업의 diff 요약(`git -C <작업 폴더> diff --stat`)을 사용자에게 보여 주고,
   주 작업 트리로 가져올지 묻습니다. 가져오면 `git -C <작업 폴더> diff > <scratchpad>/task.patch` 후
   주 작업 트리에서 `git apply`(hook이 확인을 받음). 작업 폴더는 그다음 `git worktree remove`로 지웁니다.
5. **판정:** `python scripts/gate.py <단계> --ledger out/loop/<id>/ledger.json`. 결과가 필요하면
   회귀를 먼저 돌립니다(`start_regression` 또는 `scripts/regress.py`, gate가 rerun 명령을 알려 줌).

## 멈추고 사람에게 묻는 지점
- gate가 같은 이유로 **두 번 연속** FAIL
- builder나 sim-triage가 **RTL을 의심** → confirm-hypothesis 또는 file-rtl-bug로 넘기고 멈춤
- 사양 밖 자극이 필요하거나, 검사 기준선(`check_baseline.json`)을 바꿔야 할 때
- 병합할 때(위 4번), 커밋할 때(사용자가 요청할 때만)

## 보고
짧은 표: 끝낸 작업, 추가한 테스트, 실제로 돌린 회귀 집계(runs/fail/xfail)와 rerun 명령, gate 판정,
ledger 경로, 사람이 정할 것.
