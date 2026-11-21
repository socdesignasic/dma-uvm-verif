---
name: file-rtl-bug
description: 시뮬레이션이 드러낸 RTL 버그 하나를 BUGS.md, plan.toml, sim_cfg.json known_fail, SIGNOFF.md waiver 표에 한 번에 등록하고, plan_check와 재현 실행으로 확인한 뒤 멈춰서 사용자에게 보고합니다. sim-triage가 실패를 RTL 버그로 분류했거나 가설(H1~H6)이 확인됐을 때 사용합니다. RTL은 고치지 않습니다.
---
# file-rtl-bug: RTL 버그 등록 절차

CLAUDE.md 규칙 1의 절차를 빠짐없이, 같은 순서로 하기 위한 스킬입니다. RTL(`HW/`)은 고치지 않습니다.
등록이 끝나면 **멈추고 보고**합니다(사람 확인 지점). 커밋하지 않습니다.

## 입력
- 실패한 실행의 `rerun` 명령 (예: `python scripts/sim.py run --tb top --test dma_x_test --seed 3`)
- 증거: 로그 발췌(`get_log_excerpt`), 가능하면 파형이나 신호 추적, RTL 근거 줄(`HW/...:줄`)
- 가설에서 왔으면 그 가설 ID (`verif/plan.toml`의 hypotheses)

## 순서 (순서가 중요: hook이 BUGS.md에 없는 ID의 known_fail 등록을 막음)
1. **재현 확인:** `rerun` 명령을 그대로 다시 돌려 같은 실패가 나는지 봅니다. 재현되지 않으면 등록하지 않고 보고합니다.
2. **새 ID:** `verif/BUGS.md`와 `verif/plan.toml`의 bugs에서 가장 큰 BUG 번호 + 1.
3. **`verif/BUGS.md`:** `## BUG-xxx: <한 줄 제목>` 절을 기존 절과 같은 형식으로 씁니다.
   발견(테스트, seed), 상태(`open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)`), 재현(rerun 명령),
   증상, 원인(RTL 근거 줄), 수정 제안.
4. **`verif/plan.toml`:**
   - `[[bugs]]` 추가: `id`, `kind = "bug"`, `status = "open"`, `title`, `known_fail = ["<tb>/<test>", ...]`, `waiver = ""`
   - 이 버그로 막힌 기능: `status = "blocked"`, `bug = "BUG-xxx"`
   - 가설에서 왔으면 그 가설: `status = "confirmed"`, `bug = "BUG-xxx"`, `test = "<tb>/<test>"`
5. **`verif/sim_cfg.json`:** 재현 테스트를 그 TB의 `known_fail`에 `"BUG-xxx: <한 줄 설명> - verif/BUGS.md 참고"`로 넣습니다.
6. **`verif/SIGNOFF.md`:** "현재 waiver" 표에 행을 추가합니다(ID, 내용, 상태, 재현 테스트, 출시 영향).
   사용자는 2026-11-19에 "2단계에서 가설이 확인되면 release 판정에 새 waiver가 붙는 것"을 받아들였습니다.
   그래도 waiver마다 SIGNOFF.md의 승인 절차(RTL 담당자가 상태를 정함)는 그대로입니다.
7. **확인:**
   - `python scripts/plan_check.py --write` → OK (vplan.md에 ❌ 행과 버그 표가 생김)
   - 재현 테스트를 다시 돌려 판정이 XFAIL인지 확인
   - `python scripts/gate.py static` → PASS
8. **멈추고 보고:** 아래를 짧게 적고 끝냅니다. 다음 작업으로 넘어가지 않습니다.
   - 버그 ID와 제목, 증상, 원인(근거 줄), 재현 명령과 실제로 본 판정
   - 바꾼 파일 목록
   - 사람이 정할 것: RTL 담당자의 상태 결정(open 유지 / won't fix), release 영향

## 하지 않는 것
- RTL 수정, 검사를 낮추거나 지우기, 테스트를 suite에서 빼기 (hook과 `check_inventory.py`가 막음)
- 재현하지 못한 실패의 등록
- 커밋과 push (사용자가 요청할 때만)
