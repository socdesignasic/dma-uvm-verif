---
name: confirm-hypothesis
description: verif/plan.toml의 가설(H1~H6 등) 하나를 시뮬레이션으로 확인하거나 기각합니다. rtl-reviewer로 메커니즘과 볼 신호를 정하고, uvm-builder가 worktree에서 directed test를 만들고, trace_signals로 신호를 보고 판정합니다. 확인되면 file-rtl-bug로 넘기기 전에 멈추고 보고합니다. 사용자가 가설 확인을 요청하거나 TB 2단계에서 사용합니다.
---
# confirm-hypothesis: 가설 확인

입력: 가설 ID. RTL은 고치지 않습니다. 결론은 실행한 결과로만 냅니다(규칙 4).

1. **근거 정리:** `list_known_bugs`로 가설의 제목, 근거 줄, 지정된 test를 봅니다. rtl-reviewer에 가설 ID를 주고
   메커니즘(사이클 단위), 확인할 자극 순서, 기대 동작과 가설이 맞을 때의 동작, 볼 HDL 객체와 시간 구간을 받습니다.
2. **directed test:** 작업 브랜치에서 worktree를 만들고(`git worktree add --detach`, verify-stage 2번과 같음) uvm-builder에게
   그 경로를 넘겨 그 자극을 넣는 테스트를 만듭니다. 테스트는 **사양대로의 기대
   동작을 검사**합니다(가설이 맞으면 그 검사가 실패해야 함). 등록은 add-test 절차를 따르고, plan.toml 가설의
   `test`에 이름을 적습니다. tb-reviewer 검토를 거칩니다.
3. **실행:** seed 1과 랜덤 seed 2개 이상. 실패하면 `trace_signals`(workspace=작업 폴더)로 rtl-reviewer가 말한
   구간을 봅니다. 신호 타임라인이 메커니즘과 맞는지 확인합니다. 테스트 자체의 버그가 아닌지 sim-triage로도 봅니다.
4. **판정:**
   - **기각:** 기대 동작대로 통과. plan.toml 가설의 `status = "refuted"`, 근거(실행 rerun, 본 구간) 한 줄.
     테스트는 회귀 테스트로 남깁니다.
   - **확인:** 실패가 메커니즘과 맞음. **여기서 멈추고 보고**합니다: 증상, 신호 타임라인, 근거 줄, rerun 명령.
     사용자가 확인하면 file-rtl-bug로 등록합니다(가설은 confirmed, bug ID 연결).
   - **모름:** 재현되지 않거나 다른 원인. 무엇을 더 봐야 하는지 적고 status는 open으로 둡니다.
5. `python scripts/plan_check.py --write`, `python scripts/gate.py static`, `ledger_append`로 기록합니다.
